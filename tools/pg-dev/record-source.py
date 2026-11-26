#!/usr/bin/env python3
"""Record local source identity and export reviewable patches without changing Git indexes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

work = Path(__file__).resolve().parent.parent
output = work / 'pg-dev/patches'
output.mkdir(exist_ok=True)
manifest = {'recorded_at': datetime.now(timezone.utc).isoformat(), 'repositories': []}
for name in ('higress', 'proxy-wasm-rust-sdk', 'proxy-wasm-cpp-host', 'higress/envoy/envoy'):
    repo = work / name
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=repo)
    base = git('rev-parse', 'HEAD').decode().strip()
    changed = git('diff', '--name-only', '-z').decode().split('\0')
    new = git('ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')
    files = {}
    for relative in sorted(set(changed + new) - {''}):
        path = repo / relative
        if path.is_file():
            files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    # Nested Envoy changes have their own patch; omit the unchanged submodule pointer.
    patch = git('diff', '--binary', '--', '.', ':(exclude)envoy/envoy') if name == 'higress' else git('diff', '--binary')
    for relative in sorted(set(new) - {''}):
        result = subprocess.run(['git', 'diff', '--no-index', '--binary', '--', '/dev/null', relative], cwd=repo, stdout=subprocess.PIPE, check=False)
        if result.returncode not in (0, 1):
            raise RuntimeError(f'cannot export {name}/{relative}')
        patch += result.stdout
    patch_name = name.replace('/', '-') + '.patch'
    (output / patch_name).write_bytes(patch)
    manifest['repositories'].append({'path': name, 'base_sha': base, 'patch': 'patches/' + patch_name,
        'patch_sha256': hashlib.sha256(patch).hexdigest(), 'files_sha256': files})
(work/'pg-dev/source-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({'repositories': len(manifest['repositories']), 'patches': str(output)}, ensure_ascii=False))
