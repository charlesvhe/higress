#!/usr/bin/env python3
"""Check that the verification Wasm has the PG ABI and no accidental imports."""
import hashlib
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
assert data[:8] == b'\x00asm\x01\x00\x00\x00'
def leb(buffer, position):
    value = shift = 0
    while True:
        byte = buffer[position]
        position += 1
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, position
        shift += 7
        assert shift <= 35

def string(buffer, position):
    length, position = leb(buffer, position)
    return buffer[position:position + length].decode(), position + length

imports, exports = [], []
position = 8
while position < len(data):
    section = data[position]
    length, start = leb(data, position + 1)
    body = data[start:start + length]
    position = start + length
    if section not in (2, 7):
        continue
    count, cursor = leb(body, 0)
    for _ in range(count):
        if section == 2:
            module, cursor = string(body, cursor)
            name, cursor = string(body, cursor)
            kind = body[cursor]
            cursor += 1
            assert kind == 0, (module, name, kind)
            _, cursor = leb(body, cursor)
            imports.append(module + '.' + name)
        else:
            name, cursor = string(body, cursor)
            cursor += 1
            _, cursor = leb(body, cursor)
            exports.append(name)
assert {'env.proxy_pg_init', 'env.proxy_pg_call'} <= set(imports)
assert {'_initialize', 'proxy_on_pg_call_response'} <= set(exports)
assert all(name.startswith(('env.proxy_', 'wasi_snapshot_preview1.')) for name in imports), imports
result = {'file': str(path), 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
          'imports': imports, 'exports': exports}
print(json.dumps(result, indent=2))
