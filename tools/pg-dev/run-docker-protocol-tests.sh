#!/bin/sh
set -eu
PG_WORK=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_CONTAINER=higress-pg-sdk-test
PG_IMAGE=${PG_TEST_IMAGE:-postgres:16.6-alpine}
PG_EVIDENCE="$PG_WORK/evidence/${PG_EVIDENCE_NAME:-docker}"
mkdir -p "$PG_EVIDENCE"
set -- "$PG_IMAGE"
if [ -n "${PG_TEST_TLS_DIR:-}" ]; then
  set -- --entrypoint /bin/sh -v "$PG_TEST_TLS_DIR:/pg-fixture:ro" "$PG_IMAGE" -c 'cp /pg-fixture/server.key /tmp/pg-server.key; cp /pg-fixture/server.crt /tmp/pg-server.crt; chown postgres:postgres /tmp/pg-server.key /tmp/pg-server.crt; chmod 600 /tmp/pg-server.key; exec docker-entrypoint.sh postgres -c ssl=on -c ssl_key_file=/tmp/pg-server.key -c ssl_cert_file=/tmp/pg-server.crt'
fi
# The explicit name protects unrelated containers; run refuses if the name already exists.
docker run --rm --name "$PG_CONTAINER" -d --tmpfs /var/lib/postgresql/data \
  -e POSTGRES_USER=higress_scram -e POSTGRES_PASSWORD=test-password -e POSTGRES_DB=postgres \
  -e 'POSTGRES_INITDB_ARGS=--auth-host=md5 --auth-local=trust' \
  -p 127.0.0.1:65433:5432 "$@" > "$PG_EVIDENCE/container-id"
cleanup() {
  docker logs "$PG_CONTAINER" > "$PG_EVIDENCE/postgres.log" 2>&1 || true
  docker rm -f "$PG_CONTAINER" > "$PG_EVIDENCE/cleanup.log" 2>&1 || true
}
trap cleanup EXIT INT TERM
PG_READY=0
for PG_ATTEMPT in $(seq 1 30); do
  if docker exec "$PG_CONTAINER" pg_isready -U higress_scram -d postgres >/dev/null 2>&1; then PG_READY=1; break; fi
  sleep 1
done
[ "$PG_READY" = 1 ] || { echo 'PostgreSQL did not become ready' >&2; exit 1; }
docker image inspect "$PG_IMAGE" --format '{{json .RepoDigests}}' > "$PG_EVIDENCE/image-digests.json"
docker exec -i "$PG_CONTAINER" psql -U higress_scram -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SET password_encryption = 'scram-sha-256';
ALTER ROLE higress_scram PASSWORD 'test-password';
SET password_encryption = 'md5';
CREATE ROLE higress_md5 LOGIN PASSWORD 'test-password';
SET password_encryption = 'scram-sha-256';
CREATE ROLE higress_unicode LOGIN PASSWORD 'I­X';
SQL
set --
if [ -n "${PG_TEST_TLS_DIR:-}" ]; then set -- "$PG_TEST_TLS_DIR/ca.crt" postgres.local; fi
"$PG_WORK/protocol_integration" 65433 higress_scram test-password "$@" > "$PG_EVIDENCE/scram.json"
"$PG_WORK/protocol_integration" 65433 higress_md5 test-password "$@" > "$PG_EVIDENCE/md5.json"
"$PG_WORK/protocol_integration" 65433 higress_unicode 'I­X' "$@" > "$PG_EVIDENCE/unicode-scram.json"
if "$PG_WORK/protocol_integration" 65433 higress_scram wrong-password "$@" > "$PG_EVIDENCE/wrong-password.stdout" 2> "$PG_EVIDENCE/wrong-password.stderr"; then
  echo 'wrong password unexpectedly succeeded' >&2
  exit 1
fi
if [ -n "${PG_TEST_TLS_DIR:-}" ]; then
  if "$PG_WORK/protocol_integration" 65433 higress_scram test-password "$PG_TEST_TLS_DIR/ca.crt" wrong.example > "$PG_EVIDENCE/wrong-hostname.stdout" 2> "$PG_EVIDENCE/wrong-hostname.stderr"; then
    echo 'wrong TLS hostname unexpectedly succeeded' >&2; exit 1
  fi
  if "$PG_WORK/protocol_integration" 65433 higress_scram test-password "$PG_TEST_TLS_DIR/untrusted-ca.crt" postgres.local > "$PG_EVIDENCE/wrong-ca.stdout" 2> "$PG_EVIDENCE/wrong-ca.stderr"; then
    echo 'untrusted TLS CA unexpectedly succeeded' >&2; exit 1
  fi
fi
cat "$PG_EVIDENCE/scram.json" "$PG_EVIDENCE/md5.json" "$PG_EVIDENCE/unicode-scram.json"

python3 - "$PG_EVIDENCE" <<'PY_CHECK'
import json,sys
from pathlib import Path
p = Path(sys.argv[1])
assert json.loads((p/'scram.json').read_text())['authentication_method'] == 12
assert json.loads((p/'md5.json').read_text())['authentication_method'] == 5
assert json.loads((p/'unicode-scram.json').read_text())['scram_verified']
PY_CHECK
if [ -n "${PG_ENVOY_BINARY:-}" ]; then
  if [ -n "${PG_TEST_TLS_DIR:-}" ]; then
    python3 "$PG_WORK/run-wasm-e2e.py" --envoy "$PG_ENVOY_BINARY" --runtime "${PG_WASM_RUNTIME:-v8}" --tls-ca "$PG_TEST_TLS_DIR/ca.crt"
  else
    python3 "$PG_WORK/run-wasm-e2e.py" --envoy "$PG_ENVOY_BINARY" --runtime "${PG_WASM_RUNTIME:-v8}"
  fi
fi
