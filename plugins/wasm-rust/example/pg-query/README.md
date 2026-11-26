# PG 查询验证插件

用于验证本地定制网关的 PostgreSQL ABI。原版 Higress 2.2.6 无此接口。

SDK 与所有 Rust 插件的 `proxy-wasm` 依赖统一锁定到个人 fork
`charlesvhe/proxy-wasm-rust-sdk` 的提交 `339466a0ceec01e5a7d05347e9d86f57c1daa218`，
避免同时加载两份不同来源的 Context trait。

按照 [验证工作区说明](../../../../tools/pg-dev/README.md) 检出并复制验证脚本后，
在工作区根目录执行 `./pg-dev/build-rust.sh`，产物位于
`example/pg-query/target/wasm32-wasip1/release/pg_query.wasm`。
脚本处理新 Rust WASI reactor CRT 与 SDK `_initialize` 的重复定义；不修改既有插件入口宏。

插件配置示例（JSON）：

```json
{"cluster":"pg","username":"app","password":"test-password","database":"postgres","tls_mode":"disable","timeout_ms":500,"max_rows":1000}
```

这里的明文配置仅供隔离测试。`tls_mode` 默认 `require`，需要配置 PG cluster 的
`envoy.transport_sockets.starttls` transport socket，并在 TLS context 中配置 CA 和 SAN 校验。
`disable` 必须显式选择。

HTTP 请求体是查询信封，例如：

```json
{"sql":"SELECT $1::int8, $2::text","params":[{"type_oid":20,"value":"123"},{"type_oid":25,"value":null}]}
```

插件通过本地响应返回列、行和命令标签；不将该接口作为公开 SQL 服务部署。
调用成功后暂停 HTTP 流，PG 回调返回本地响应；请求结束后的回调由 SDK/宿主取消。

协议、连接池及构建背景见 [技术方案](../../../../docs/developers/async-postgres.md) 和 [验证说明](../../../../tools/pg-dev/README.md)。
