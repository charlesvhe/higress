# 个人 fork 的检出与复现

本目录是可发布的验证资料源。脚本沿用原验证工作区的布局：同级 `higress/`、`proxy-wasm-rust-sdk/`、`proxy-wasm-cpp-host/`、`pg-dev/`。请在新的工作目录中检出，然后将本目录复制为同级 `pg-dev/` 后运行脚本。

```sh
git clone --branch feat/async-postgres-2.2.6 https://github.com/charlesvhe/higress.git higress
git clone --branch feat/async-postgres-2.2.6 https://github.com/charlesvhe/proxy-wasm-rust-sdk.git proxy-wasm-rust-sdk
git clone --branch feat/async-postgres-2.2.6 https://github.com/charlesvhe/proxy-wasm-cpp-host.git proxy-wasm-cpp-host
git -C proxy-wasm-rust-sdk checkout 339466a0ceec01e5a7d05347e9d86f57c1daa218
git -C proxy-wasm-cpp-host checkout dec0d9632dbf523c67a93abbfbb220444802bb9e
git -C higress submodule update --init envoy/envoy istio/proxy
cp -R higress/tools/pg-dev ./pg-dev
./pg-dev/build-rust.sh
```

单独构建 Rust 插件时，Cargo 自动获取固定的个人 SDK 提交；完整验证工作区额外检出 SDK 和 C++ host，是为了运行 SDK 单元测试和使用构建脚本的本地 repository override。

独立 codec 驱动还需要 OpenSSL/ICU 开发库及以下固定测试源码：

```sh
git clone --depth 1 --branch v1.15.2 https://github.com/google/googletest.git pg-dev/deps/googletest
mkdir -p pg-dev/deps/include/nlohmann
curl --fail --location https://raw.githubusercontent.com/nlohmann/json/v3.12.0/single_include/nlohmann/json.hpp -o pg-dev/deps/include/nlohmann/json.hpp
./pg-dev/build-codec-tests.sh
./pg-dev/run-docker-protocol-tests.sh
./pg-dev/run-docker-tls-tests.sh
```

方案见 [async-postgres.md](../../docs/developers/async-postgres.md)。`source-manifest.json` 和 `patches/` 保留首次完整数据面测试时的源码快照；发布后的依赖关联见 `published-revisions.json`，后续发布检查见 `evidence/publication/`。原始证据中的本机绝对路径用于溯源；可执行模板位于本目录顶层。

---

# PostgreSQL 原生异步访问：本地定制实现与验证

本目录配套本次 PostgreSQL 本地定制方案。用户已授权本地定制跳过上游 issue-spec 流程，并授权将实现发布到 `charlesvhe` 的个人 fork。

## 实现位置

- `proxy-wasm-rust-sdk/src/hostcalls.rs`：PG init/call/响应读取，保留未知 ABI 状态数值。
- `proxy-wasm-rust-sdk/src/dispatcher.rs`：token 与上下文分发、回调去重、删除时释放捕获对象。
- `higress/plugins/wasm-rust/src/pg_wrapper.rs`：Builder、客户端、参数、结果和错误类型。
- `proxy-wasm-cpp-host/`：PG 导入／导出、缓冲区编号 10、三位 token 类型及回绕时的在途 ID 保护。
- `higress/envoy/envoy/source/common/postgres/`：PG v3 codec、SCRAM/MD5、StartTLS、异步连接池。
- `higress/envoy/envoy/source/extensions/common/wasm/context.*`：宿主接入、配置代与请求生命周期。
- `higress/plugins/wasm-rust/example/pg-query/`：通过 HTTP 请求体验证单条 SQL 的 Wasm 插件。

所有 Rust 包统一使用 `charlesvhe/proxy-wasm-rust-sdk` 的固定提交 `339466a0ceec01e5a7d05347e9d86f57c1daa218`，Cargo.lock 同步锁定该 Git 来源，避免 Context trait 来自不同 crate 实例。原始验证阶段曾使用同级本地 path；个人 fork 发布时已改为可直接获取的 Git 依赖并重新验证。

## 协议与运行约定

- PG 连接由 Envoy 管理，Wasm 不访问 socket；没有 HTTP 桥接和 Tokio 运行时。
- `proxy_pg_init` 返回 root 配置作用域的句柄，懒建连。重新配置使旧句柄失效；已有在途操作持有其原客户端完成。
- 查询使用 `Parse/Bind/Describe/Execute/Sync`；多条语句由数据库拒绝，不按分号切割字符串。
- 单个连接同一时刻执行一个查询；结果经过 `ReadyForQuery(I)` 和 `DISCARD ALL` 会话复位后回调，复位异常关闭连接。
- 首期参数和行值均为 PG text format；NULL、空字符串分开保存，数字不经 JSON 浮点转换。列按顺序保存，允许重名列。
- 不提供事务、COPY、游标、pipelining 或通知订阅接口；单条语句并不等于数据库只读权限。
- 超时包含排队、必要建连、查询及复位。取消和超时关闭正在使用的连接；不声称服务端已立即停止执行，也不自动重试查询。
- `tls_mode=require` 通过 SSLRequest + Envoy StartTLS 连接，并要求 peer certificate 已验证；CA、SNI 和 SAN 必须在 cluster 的 TLS context 配置。显式 `disable` 仅用于隔离测试。完整 StartTLS cluster 模板见 `pg-tls-cluster.json`（证书路径和主机名需替换）；该模板已用于本次 macOS/WAMR 宿主的真实 TLS 数据面测试。
- SCRAM-SHA-256 核验服务端签名，采用 ICU RFC4013 SASLprep；SCRAM 迭代次数上限 100000。ICU 数据过滤器同时纳入 stringprep、normalization 和 unicore，避免仅在开发机完整 ICU 上认证成功。MD5 和 trust 也支持；cleartext password 仅允许已验证 TLS。暂不支持 PLUS/GSS/SSPI。
- 每 worker 的硬上限：128 客户端、256 连接、2048 在途请求，以及 512 MiB 的保守内存预约预算。预约包含 JSON/协议副本开销，不等同于实测 RSS；单客户端限额仍单独生效。
- 原始 hostcall 的 JSON 信封除字节限制外，嵌套深度最多 16，包含未知字段，避免深层输入造成无界 DOM 嵌套。
- 密码、SQL 和参数不作为 SDK 日志或指标标签。数据库 ErrorResponse 的诊断文本可能回显输入，因此返回稳定错误消息及经过格式校验的 SQLSTATE。

## 已准备的验证入口

### Rust

需要 Cargo、Rust Wasm 目标及 rustfmt/clippy。执行位置为工作区根目录：

```sh
cargo test --manifest-path proxy-wasm-rust-sdk/Cargo.toml --lib
cargo clippy --manifest-path proxy-wasm-rust-sdk/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path higress/plugins/wasm-rust/Cargo.toml --lib
cargo clippy --manifest-path higress/plugins/wasm-rust/Cargo.toml --all-targets -- -D warnings
./pg-dev/build-rust.sh
```

本机 Cargo 在 rustup toolchain 的 bin 目录中；脚本会通过 `rustup which cargo` 定位。新 Rust WASI reactor CRT 和本 SDK 的 `_initialize` 存在重复定义，脚本显式保留 SDK 入口并链接 WASI libc。`verify-wasm.py` 校验 PG imports、回调 export 和所有未解析导入，不将缺失的应用符号误当成正常宿主接口。

### C++ codec

Bazel 目标：

```sh
bazel test //test/common/postgres:codec_test
bazel test //test/common/postgres:async_client_test
bazel build //source/extensions/common/wasm:wasm_lib
```

上述命令在修改后的 Envoy 仓库执行，构建宿主目标时附加：

```text
--override_repository=proxy_wasm_cpp_host=/绝对路径/proxy-wasm-cpp-host
```

本机另使用 Apple Clang + OpenSSL + ICU + GoogleTest 独立编译同一份 codec/test 源码，并运行 ASan/UBSan，命令为 `PG_SANITIZE=1 ./pg-dev/build-codec-tests.sh`。默认使用 Homebrew 的 OpenSSL/ICU 路径；其他系统可用 `PG_OPENSSL_PREFIX`、`PG_ICU_PREFIX` 指定安装前缀。测试依赖固定为 nlohmann/json v3.12.0 和 GoogleTest v1.15.2，位于 `pg-dev/deps/`。独立测试不覆盖 Envoy dispatcher 或 Wasm 生命周期；异步客户端的四个生命周期用例位于 `async_client_test.cc`，需运行对应 Bazel 目标。

### Docker PostgreSQL 协议验证

```sh
./pg-dev/run-docker-protocol-tests.sh
./pg-dev/run-docker-tls-tests.sh
```

脚本使用 `postgres:16.6-alpine`、仅绑定 localhost:65433，创建专用容器 `higress-pg-sdk-test`，结束后自动删除。启动遇到同名现有容器会失败，不删除其他容器。

验证驱动 `protocol_integration.cc` 直接使用生产 codec，测试 SCRAM、MD5、Unicode/SASLprep、错误密码、参数绑定、NULL/空串、int8/numeric 精度、Unicode 行值、分号与多语句、SQLSTATE、错误后复用、会话复位和行数上限。驱动中的阻塞 socket 仅存在于测试程序；生产客户端使用 Envoy dispatcher。

镜像 digest、结果和清理记录位于 `evidence/docker/`；TLS 验证记录在 `evidence/docker-tls/`，另覆盖错误 CA 和错误主机名的拒绝。该层是“生产 codec ↔ 真实 PG”的测试，不等同于 Envoy/Wasm 端到端测试。

### Envoy/Wasm 端到端

先准备同平台的自编译 Envoy 二进制，再执行：

```sh
PG_ENVOY_BINARY=/绝对路径/自编译envoy ./pg-dev/run-docker-protocol-tests.sh
```

会额外运行 `run-wasm-e2e.py`，使用 localhost:19000 和 19001，测试真实 Wasm 的查询、参数、Unicode、重名列、零行、SQLSTATE/诊断脱敏、结果超限、非 idle 事务拒绝、服务端断连、超时、并发上下文隔离及请求断开恢复。`envoy.json` 是配置模板，由脚本填入 Wasm 绝对路径。

Linux 容器中的 Envoy 不能作为 macOS 原生子进程启动；`PG_ENVOY_BINARY` 需要与运行 Python 的系统匹配。此入口不会替换或重启现有业务网关。

### Linux 网关构建和身份校验

```sh
./pg-dev/build-envoy-linux.sh
PG_BASE_IMAGE='已固定digest的Higress2.2.6镜像' ./pg-dev/build-gateway.sh
```

第一步在 Higress 固定 build-tools 镜像内直接编译修改后的 Istio Proxy/Envoy/C++ host，使用本地 repository override，不读取旧 `external/envoy` 副本，不下载原版预编译 Envoy。

第二步仅在本地构建 `higress-pg:local`，并比较产物二进制与容器内二进制的 SHA-256；不推送镜像。它要求 Linux ELF 产物，避免误将 macOS 二进制打入网关。

## 证据与完成状态

本次已完成本地代码与 macOS/WAMR 数据面验证。证据位于 `evidence/`、`source-manifest.json` 和 `wasm-manifest.json`；完整 Linux/V8 网关与部署镜像尚未构建。

本次准备了固定 Bazel 7.7.1。其 Java 运行时对工作区中文路径出现编码错误，因此额外在 `/private/tmp/higress-pg-src/` 创建了英文路径源码副本用于检查；临时副本跳过了无关的 Rust dynamic module crate 索引生成，并为无 .git 副本提供基线 SHA、补丁摘要和 `Modified` 状态的 workspace-status 脚本（保存在 `evidence/bazel/`），不标记为原版 Clean 构建。正式 Linux 构建脚本直接挂载原仓库，不使用这些临时处理。

### macOS 验证 profile 的构建约定

`minimal-extensions/` 仅注册 HTTP/Wasm、静态 PG cluster、必要 DNS 和 raw/TLS/StartTLS 扩展，以 WAMR 解释执行真实 Rust Wasm。它用于本机数据面验收，不替代包含全部扩展的 Linux/V8 Higress 网关。

本机 Xcode 27.2 / Apple Clang 21 还需要以下构建适配，仅作用于英文路径临时副本或生成工具链：

- 将 SDK 根路径及其解析后的实际路径纳入生成的 `local_config_cc` builtin includes。
- 临时 Bazel binary/test 宏在 Apple 平台省略 `-lcrypt`；macOS 使用 libSystem，不改 Linux 链接行为。
- 选用已安装的 JDK 25（Java 语言目标仍为 11），通过 `--java_runtime_version=local_jdk --tool_java_runtime_version=local_jdk --extra_toolchains=@local_jdk//:local_jdk_toolchain_java11_definition` 避免重复下载远程 JDK。
- `--per_file_copt=.*(wasm|expr).*@-Wno-error=nontrivial-memcall` 处理既有 CEL 依赖在新版 Clang 中的警告，PG 模块仍按默认错误策略编译。

核心构建参数为 `--define=wasm=wamr`，并 override 本地 C++ host 与 `minimal-extensions`。构建的目标包括 PG 两组测试、`//test/extensions/common/wasm:wasm_test`、`//source/extensions/common/wasm:wasm_lib` 及 `//source/exe:envoy-static`。实际通过情况以运行日志为准。

### 源码交付记录

执行 `./pg-dev/record-source.py`，生成四个仓库的 `patches/*.patch` 及 `source-manifest.json`。脚本只读仓库，不更改 Git index、提交或分支；补丁包含新增文件。manifest 记录基线 SHA、补丁 SHA-256 和各修改文件 SHA-256，可用于核对编译与交付源码。现有工作区已经应用这些改动，补丁用于审查或在相同基线的干净副本中应用。

主验证数据库为 PostgreSQL 16.6，另已完成 PostgreSQL 17.2 的明文协议兼容冒烟（`evidence/docker-pg17/`）。完整 Linux/V8 网关构建和部署镜像仅在产生对应运行证据后记为通过。

实际已通过的基础验证：Rust 下层 SDK 3 项、上层 SDK 15 项及 Clippy；生产 codec 8 项（含 ASan/UBSan）；Bazel 异步生命周期 4 项；既有 Wasm NullVm 44 项。Bazel 日志副本位于 `evidence/bazel/`。测试用英文路径副本的 24 个改动 C++ 文件已逐一与交付 manifest 的 SHA-256 核对一致，见 `staged-source-identity.json`。

固定 C++ host 原先使用 WAMR 的旧 `WASM_ANYREF` 名称，而 Envoy 固定的 WAMR 2.2 使用 `WASM_EXTERNREF`。本次将诊断打印中的该 case 改为两版共有的 Wasm C API 类型值 128，以使该验证运行时可编译；不改变标量 hostcall 的 ABI。

### 首次数据面结果（本地 path SDK）

| 验证 | 结果与证据 |
| --- | --- |
| 自编译 Envoy/WAMR + 真实 Rust Wasm + PG 16.6 明文 | 12 组通过，`evidence/wasm/results.json` |
| 同一 Envoy/Wasm + PG 16.6 StartTLS | 12 组通过，`evidence/wasm-tls/results.json` |
| 既有 Wasm filter 的 NullVm 回归 | 90 项通过，含 HTTP async call、Redis 和 gRPC，`evidence/bazel/callout-regression.log` |
| PG 16.6 生产 codec 的真实数据库验证 | 明文及 TLS 各三种认证 × 12 项；另验证错误密码、CA、主机名，`evidence/docker*/` |
| PG 17.2 生产 codec 兼容冒烟 | 三种认证 × 12 项及错误密码拒绝，`evidence/docker-pg17/` |

数据面检查包括 24 个并发请求的上下文隔离。连接断开测试使用 TCP reset，并要求取消指标增加；两组结束前 `active=0`、`pending=0`、`cancelled=1`。此时连接池仍可保留有界空闲连接，随后停止测试宿主和数据库容器；脚本检查 19000/19001 监听端口已释放。

最终 Envoy SHA-256：`b106e4fd427d2eb9a923858dafd30278253a452ff6f1562e5e02d21d7fe1518e`。
Wasm SHA-256：`59eb72c05523e85e5d7a29d97186ade9653812c571bf17645a0556024f0bb738`。
宿主验证产物为 `artifacts/envoy-native`（macOS ARM64），不能用于 Linux 网关镜像。

完整链路测试发现并修正了通用 `get_buffer_bytes` / `get_buffer_status` 对新增编号 10 的校验；`set_buffer_bytes` 明确拒绝 PG 响应缓冲写入。修正后的宿主重新编译，并复跑了上述数据面及既有回归。

原版网关的对照验证也已执行：只读挂载同一 Wasm，在原版镜像中运行 `--mode validate`，按预期因缺少 `proxy_pg_*` 导入失败。原版 Envoy 版本、镜像 digest 和日志位于 `evidence/stock-gateway/`。该结果说明新增能力来自定制宿主；不将原版不支持新 ABI 视为回归。

机器可读汇总为 `evidence/results.json`。官方 ARM64 构建工具镜像已拉取（digest 见 `artifacts/build-tools-digests.json`）；本次未将其已下载表述为 Linux/V8 网关编译通过。

### 个人 fork 发布复测

Rust 依赖改为固定个人 Git rev 后，使用 `--locked` 重新运行上层 SDK 15 项测试、SDK 和插件 Clippy 及 Wasm release 构建，均通过。新 Wasm 再次通过真实 PG 明文／StartTLS 两组各 12 项数据面检查，见 `evidence/publication/results.json`。

发布复测 Wasm SHA-256：`9cf7877bad2f30449a2468543facae1d0dd480b52885df79e6e89c2a4d809dfe`。验证宿主 SHA-256 仍为 `b106e4fd427d2eb9a923858dafd30278253a452ff6f1562e5e02d21d7fe1518e`；已核对发布的 C++ host 源码归档与原验证的所有改动 C++ 文件逐一一致。Envoy Bazel 现在固定该归档的提交和校验和。

如需复测时另存记录，可通过 `PG_WASM_EVIDENCE_DIR` 指定 Wasm 数据面证据目录，并使用 `PG_EVIDENCE_NAME` 指定数据库驱动证据子目录。完整 Linux/V8 网关与部署镜像仍未构建。
