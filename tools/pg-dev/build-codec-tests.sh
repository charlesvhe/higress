#!/bin/sh
set -eu
PG_WORK=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PG_ROOT=$(CDPATH= cd -- "$PG_WORK/.." && pwd)
PG_CXX=${PG_CXX:-c++}
PG_OPENSSL=${PG_OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}
PG_ICU=${PG_ICU_PREFIX:-/opt/homebrew/opt/icu4c}
PG_GTEST="$PG_WORK/deps/googletest/googletest"
set --
if [ "${PG_SANITIZE:-0}" = 1 ]; then set -- -fsanitize=address,undefined -fno-omit-frame-pointer; fi
"$PG_CXX" -std=c++20 -Wall -Wextra -Werror -Wno-deprecated-declarations "$@" \
  -I"$PG_ROOT/higress/envoy/envoy" -I"$PG_WORK/deps" -isystem "$PG_GTEST/include" -I"$PG_GTEST" \
  -I"$PG_OPENSSL/include" -I"$PG_ICU/include" \
  "$PG_ROOT/higress/envoy/envoy/source/common/postgres/codec.cc" \
  "$PG_ROOT/higress/envoy/envoy/test/common/postgres/codec_test.cc" \
  "$PG_GTEST/src/gtest-all.cc" "$PG_GTEST/src/gtest_main.cc" \
  -L"$PG_OPENSSL/lib" -lssl -lcrypto -L"$PG_ICU/lib" -licuuc -licudata -pthread -o "$PG_WORK/codec_test"
mkdir -p "$PG_WORK/evidence"
"$PG_WORK/codec_test" > "$PG_WORK/evidence/codec-tests.log" 2>&1
"$PG_CXX" -std=c++20 -Wall -Wextra -Werror -Wno-deprecated-declarations "$@" \
  -I"$PG_ROOT/higress/envoy/envoy" -I"$PG_WORK/deps" -I"$PG_OPENSSL/include" -I"$PG_ICU/include" \
  "$PG_ROOT/higress/envoy/envoy/source/common/postgres/codec.cc" "$PG_WORK/protocol_integration.cc" \
  -L"$PG_OPENSSL/lib" -lssl -lcrypto -L"$PG_ICU/lib" -licuuc -licudata -o "$PG_WORK/protocol_integration"
