#!/bin/sh
set -eu
PG_WORK=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${PG_BASE_IMAGE:?Set PG_BASE_IMAGE to a pinned Higress 2.2.6 gateway/all-in-one image digest}"
PG_IMAGE=${PG_GATEWAY_IMAGE:-higress-pg:local}
python3 - "$PG_WORK/artifacts/envoy-linux" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes()[:4] == b'\x7fELF', 'Linux ELF binary required'
PY
docker build --build-arg "PG_BASE_IMAGE=$PG_BASE_IMAGE" -f "$PG_WORK/Dockerfile.gateway" -t "$PG_IMAGE" "$PG_WORK/artifacts"
docker run --rm --entrypoint sha256sum "$PG_IMAGE" /usr/local/bin/envoy > "$PG_WORK/artifacts/container-envoy.sha256"
python3 - "$PG_WORK/artifacts" <<'PY'
from pathlib import Path
import hashlib,sys
p = Path(sys.argv[1])
expected = hashlib.sha256((p/'envoy-linux').read_bytes()).hexdigest()
actual = (p/'container-envoy.sha256').read_text().split()[0]
assert expected == actual, 'gateway contains a different Envoy binary'
print('gateway Envoy SHA-256:', expected)
PY
docker image inspect "$PG_IMAGE" --format '{{.Id}}' > "$PG_WORK/artifacts/gateway-image-id"
