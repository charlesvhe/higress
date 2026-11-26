#!/bin/sh
set -eu
cd /private/tmp/higress-pg-src/envoy
PG_BAZEL=/Users/charles/Desktop/技术沙龙/pg-dev/bin/bazel-7.7.1-darwin-arm64
PG_WORK=/Users/charles/Desktop/技术沙龙/pg-dev
set -- --override_repository=proxy_wasm_cpp_host=/private/tmp/higress-pg-src/host --override_repository=envoy_build_config=/private/tmp/higress-pg-src/minimal-extensions --workspace_status_command=/private/tmp/higress-pg-src/envoy/pg_workspace_status.sh --repo_env=GOPROXY=https://goproxy.cn,direct --repo_env=JAVA_HOME=/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home --java_runtime_version=local_jdk --tool_java_runtime_version=local_jdk --extra_toolchains=@local_jdk//:local_jdk_toolchain_java11_definition '--per_file_copt=.*(wasm|expr).*@-Wno-error=nontrivial-memcall' --jobs=6 --curses=no --color=no --show_progress_rate_limit=30 --test_output=errors
"$PG_BAZEL" --output_user_root=/private/tmp/higress-pg-bazel-ascii test "$@" --define=wasm=wamr //test/common/postgres:codec_test //test/common/postgres:async_client_test //test/extensions/common/wasm:wasm_test //source/exe:envoy-static > "$PG_WORK/bazel-native-e2e-build-final.log" 2>&1
chmod u+w "$PG_WORK/artifacts/envoy-native"
cp bazel-bin/source/exe/envoy-static "$PG_WORK/artifacts/envoy-native"
shasum -a 256 "$PG_WORK/artifacts/envoy-native" > "$PG_WORK/artifacts/envoy-native.sha256"
cp "$PG_WORK/bazel-native-e2e-build-final.log" "$PG_WORK/evidence/bazel/native-build.log"
"$PG_BAZEL" --output_user_root=/private/tmp/higress-pg-bazel-ascii test "$@" --define=wasm=disabled //test/extensions/filters/http/wasm:wasm_filter_test > "$PG_WORK/bazel-callout-regression.log" 2>&1
