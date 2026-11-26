#!/bin/sh
set -eu
PG_WORK=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PG_TOOLS=${PG_BUILD_TOOLS_IMAGE:-higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/build-tools-proxy:master-eebcdda8856e2d4f528991d27d4808880cce4c52}
mkdir -p "$PG_WORK/pg-dev/linux-cache" "$PG_WORK/pg-dev/artifacts"
# Use the checked-out source directly: no stale external/envoy snapshot and no
# download of the stock v2.2.6 precompiled binary.
docker run --rm \
  -v "$PG_WORK:/workspace" \
  -v "$PG_WORK/pg-dev/linux-cache:/pg-cache" \
  -w /workspace/higress/istio/proxy --entrypoint /bin/bash "$PG_TOOLS" -lc '
    set -euo pipefail
    bazel --output_user_root=/pg-cache build \
      --override_repository=envoy=/workspace/higress/envoy/envoy \
      --override_repository=proxy_wasm_cpp_host=/workspace/proxy-wasm-cpp-host \
      --config=release //:envoy
    cp bazel-bin/envoy /workspace/pg-dev/artifacts/envoy-linux
    sha256sum /workspace/pg-dev/artifacts/envoy-linux > /workspace/pg-dev/artifacts/envoy-linux.sha256
  '
docker image inspect "$PG_TOOLS" --format '{{json .RepoDigests}}' > "$PG_WORK/pg-dev/artifacts/build-tools-digests.json"
