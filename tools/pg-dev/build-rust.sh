#!/bin/sh
set -eu
PG_WORK=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v cargo >/dev/null 2>&1; then
  PG_CARGO=$(rustup which cargo)
  PATH="$(dirname "$PG_CARGO"):$PATH"
  export PATH
fi
PG_SYSROOT=$(rustc --print sysroot)
# This SDK's _initialize owns Wasm constructors. New WASI reactor CRTs also define
# _initialize, so omit that CRT while retaining its libc and explicit host imports.
export CARGO_PROFILE_RELEASE_STRIP=none
export RUSTFLAGS="-C link-self-contained=no -L native=$PG_SYSROOT/lib/rustlib/wasm32-wasip1/lib/self-contained -C link-arg=--allow-undefined"
cargo build --locked --manifest-path "$PG_WORK/higress/plugins/wasm-rust/example/pg-query/Cargo.toml" --target wasm32-wasip1 --release

python3 "$PG_WORK/pg-dev/verify-wasm.py" "$PG_WORK/higress/plugins/wasm-rust/example/pg-query/target/wasm32-wasip1/release/pg_query.wasm" > "$PG_WORK/pg-dev/wasm-manifest.json"
