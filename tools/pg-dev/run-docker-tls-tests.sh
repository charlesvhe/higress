#!/bin/sh
set -eu
PG_WORK=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_TLS="$PG_WORK/tls-fixture"
PG_OPENSSL=${PG_OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}/bin/openssl
mkdir -p "$PG_TLS"
"$PG_OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$PG_TLS/ca.key" -out "$PG_TLS/ca.crt" -days 1 -subj '/CN=Higress PG Test CA' >/dev/null 2>&1
"$PG_OPENSSL" req -newkey rsa:2048 -nodes -keyout "$PG_TLS/server.key" -out "$PG_TLS/server.csr" -subj '/CN=postgres.local' >/dev/null 2>&1
printf '%s\n' 'subjectAltName=DNS:postgres.local' > "$PG_TLS/extensions"
"$PG_OPENSSL" x509 -req -in "$PG_TLS/server.csr" -CA "$PG_TLS/ca.crt" -CAkey "$PG_TLS/ca.key" -CAcreateserial -out "$PG_TLS/server.crt" -days 1 -extfile "$PG_TLS/extensions" >/dev/null 2>&1
"$PG_OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$PG_TLS/untrusted-ca.key" -out "$PG_TLS/untrusted-ca.crt" -days 1 -subj '/CN=Untrusted Test CA' >/dev/null 2>&1
PG_TEST_TLS_DIR="$PG_TLS" PG_EVIDENCE_NAME="${PG_EVIDENCE_NAME:-docker-tls}" "$PG_WORK/run-docker-protocol-tests.sh"
