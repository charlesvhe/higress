#!/bin/sh
set -eu
PG_WORK=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_BIN="$PG_WORK/pg-install/bin"
PG_DATA="$PG_WORK/pg-data"
PG_SOCKET="$PG_WORK/socket"
mkdir -p "$PG_SOCKET" "$PG_WORK/evidence"
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
  "$PG_BIN/initdb" -D "$PG_DATA" -A trust -U pgadmin --no-locale > "$PG_WORK/evidence/initdb.log"
fi
# This driver manages only its own data directory. Never contact a system service.
cleanup() { "$PG_BIN/pg_ctl" -D "$PG_DATA" -m fast stop > "$PG_WORK/evidence/stop.log" 2>&1 || true; }
trap cleanup EXIT INT TERM
"$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_WORK/evidence/postgres.log" -o "-h 127.0.0.1 -p 65432 -k $PG_SOCKET" start
"$PG_BIN/psql" -h "$PG_SOCKET" -p 65432 -U pgadmin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
SET password_encryption = 'scram-sha-256';
DROP ROLE IF EXISTS higress_scram;
DROP ROLE IF EXISTS higress_md5;
DROP ROLE IF EXISTS higress_unicode;
CREATE ROLE higress_scram LOGIN PASSWORD 'test-password';
CREATE ROLE higress_unicode LOGIN PASSWORD 'I­X';
SET password_encryption = 'md5';
CREATE ROLE higress_md5 LOGIN PASSWORD 'test-password';
SQL
cat > "$PG_DATA/pg_hba.conf" <<'HBA'
local all all trust
host all higress_scram 127.0.0.1/32 scram-sha-256
host all higress_unicode 127.0.0.1/32 scram-sha-256
host all higress_md5 127.0.0.1/32 md5
host all all 127.0.0.1/32 reject
HBA
"$PG_BIN/pg_ctl" -D "$PG_DATA" reload
"$PG_WORK/protocol_integration" 65432 higress_scram test-password > "$PG_WORK/evidence/scram.json"
"$PG_WORK/protocol_integration" 65432 higress_md5 test-password > "$PG_WORK/evidence/md5.json"
"$PG_WORK/protocol_integration" 65432 higress_unicode 'I­X' > "$PG_WORK/evidence/unicode-scram.json"
if "$PG_WORK/protocol_integration" 65432 higress_scram wrong-password > "$PG_WORK/evidence/wrong-password.stdout" 2> "$PG_WORK/evidence/wrong-password.stderr"; then
  echo 'wrong password unexpectedly succeeded' >&2
  exit 1
fi
cat "$PG_WORK/evidence/scram.json" "$PG_WORK/evidence/md5.json" "$PG_WORK/evidence/unicode-scram.json"
