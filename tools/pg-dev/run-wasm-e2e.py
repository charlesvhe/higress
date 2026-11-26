#!/usr/bin/env python3
"""Run the built custom Envoy + PG Wasm against an already running test database."""
import argparse
import os
import concurrent.futures
import hashlib
import json
from pathlib import Path
import socket
import struct
import re
import subprocess
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--envoy', required=True, help='custom native Envoy binary, not the stock gateway')
parser.add_argument('--pg-port', type=int, default=65433)
parser.add_argument('--tls-ca', help='enable PG StartTLS and validate this CA and postgres.local SAN')
parser.add_argument('--runtime', choices=['v8', 'wamr'], default='v8')
args = parser.parse_args()
work = Path(__file__).resolve().parent
wasm = work.parent / 'higress/plugins/wasm-rust/example/pg-query/target/wasm32-wasip1/release/pg_query.wasm'
evidence = Path(os.environ.get('PG_WASM_EVIDENCE_DIR', work / ('evidence/wasm-tls' if args.tls_ca else 'evidence/wasm'))).resolve()
evidence.mkdir(parents=True, exist_ok=True)
config = json.loads((work/'envoy.json').read_text().replace('PG_WASM_PATH', str(wasm)))
config['static_resources']['clusters'][0]['load_assignment']['endpoints'][0]['lb_endpoints'][0]['endpoint']['address']['socket_address']['port_value'] = args.pg_port
wasm_config = config['static_resources']['listeners'][0]['filter_chains'][0]['filters'][0]['typed_config']['http_filters'][0]['typed_config']['config']
wasm_config['vm_config']['runtime'] = 'envoy.wasm.runtime.' + args.runtime
if args.tls_ca:
    pg_config = json.loads(wasm_config['configuration']['value'])
    pg_config['tls_mode'] = 'require'
    wasm_config['configuration']['value'] = json.dumps(pg_config)
    cluster = json.loads((work/'pg-tls-cluster.json').read_text())
    cluster['transport_socket']['typed_config']['tls_socket_config']['common_tls_context']['validation_context']['trusted_ca']['filename'] = str(Path(args.tls_ca).resolve())
    cluster['load_assignment']['endpoints'][0]['lb_endpoints'][0]['endpoint']['address']['socket_address']['port_value'] = args.pg_port
    config['static_resources']['clusters'][0] = cluster

config_path = evidence/'envoy.json'
config_path.write_text(json.dumps(config, indent=2)+'\n')
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def query(sql, params=()):
    body = json.dumps({'sql': sql, 'params': list(params)}).encode()
    request = urllib.request.Request('http://127.0.0.1:19000/', data=body, headers={'content-type':'application/json'})
    try:
        with opener.open(request, timeout=5) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)

# Refuse to use or disrupt an unrelated service on the harness ports.
for port in (19000, 19001):
    with socket.socket() as check:
        check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        check.bind(('127.0.0.1', port))
log = (evidence/'envoy.log').open('wb')
process = subprocess.Popen([args.envoy, '-c', str(config_path), '--concurrency', '2', '--log-level', 'info'], stdout=log, stderr=subprocess.STDOUT)
results = []
try:
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError(f'Envoy exited; inspect {evidence}/envoy.log')
        try:
            with socket.create_connection(('127.0.0.1',19000), timeout=.1):
                break
        except OSError:
            time.sleep(.1)
    else:
        raise RuntimeError('Envoy listener did not become ready')
    status, result = query('SELECT 1')
    assert status == 200 and result['rows'] == [['1']], (status,result)
    results.append('select')
    status, result = query('SELECT $1::int8, $2::text, $3::text', [
        {'type_oid':20,'value':'9223372036854775807'}, {'type_oid':25,'value':None}, {'type_oid':25,'value':''}])
    assert status == 200 and result['rows'] == [['9223372036854775807',None,'']], (status,result)
    results.append('parameters-null-empty-precision')
    status, result = query('SELECT 1; SELECT 2')
    assert status == 400 and result['sqlstate'] == '42601', (status,result)
    results.append('single-statement')
    status, result = query("SELECT '你好'::text AS same, 1.000000000000000001::numeric AS same")
    assert status == 200 and result['rows'] == [['你好','1.000000000000000001']], (status,result)
    assert [c['name'] for c in result['columns']] == ['same','same'], result
    results.append('unicode-duplicate-columns-numeric')
    status, result = query('SELECT 1 WHERE false')
    assert status == 200 and result['rows'] == [], (status,result)
    results.append('zero-rows')
    status, result = query('SELECT * FROM pg_test_table_does_not_exist')
    assert status == 400 and result['sqlstate'] == '42P01', (status,result)
    assert 'pg_test_table_does_not_exist' not in result['error'], result
    results.append('sqlstate-and-diagnostic-redaction')
    status, result = query('SELECT generate_series(1, 1001)')
    assert status == 429, (status,result)
    assert query('SELECT 7')[0] == 200
    results.append('row-limit-and-recovery')
    status, result = query('BEGIN')
    assert status == 502, (status,result)
    assert query('SELECT 8')[0] == 200
    results.append('non-idle-transaction-rejected')
    status, result = query('SELECT pg_terminate_backend(pg_backend_pid())')
    assert status == 502, (status,result)
    assert query('SELECT 9')[0] == 200
    results.append('server-disconnect-and-recovery')
    status, result = query('SELECT pg_sleep(1)')
    assert status == 504, (status,result)
    results.append('deadline')
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        futures = [pool.submit(query, f'SELECT {i}') for i in range(24)]
        for i, future in enumerate(futures):
            status, result = future.result()
            assert status == 200 and result['rows'] == [[str(i)]], (i,status,result)
    results.append('concurrent-context-isolation')
    body = json.dumps({'sql':'SELECT pg_sleep(1)'}).encode()
    with socket.create_connection(('127.0.0.1',19000)) as client:
        client.sendall(b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
        time.sleep(.05)  # allow the sleeping query to reach the native client
        client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
    time.sleep(.7)
    assert query('SELECT 42')[0] == 200
    results.append('disconnect-and-recovery')
    with opener.open('http://127.0.0.1:19001/stats?filter=wasm_pg', timeout=5) as response:
        stats = response.read()
        (evidence/'stats.txt').write_bytes(stats)
        assert b'wasm_pg.active: 0' in stats and b'wasm_pg.pending: 0' in stats, stats
        cancelled = re.search(rb'wasm_pg.cancelled: (\d+)', stats)
        assert cancelled and int(cancelled.group(1)) >= 1, stats
    identity = {'tests': results, 'envoy_sha256': hashlib.sha256(Path(args.envoy).read_bytes()).hexdigest(),
                'wasm_sha256': hashlib.sha256(wasm.read_bytes()).hexdigest(), 'runtime': args.runtime, 'tls': bool(args.tls_ca)}
    (evidence/'results.json').write_text(json.dumps(identity,indent=2)+'\n')
    print(json.dumps(identity))
finally:
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    log.close()
    for port in (19000,19001):
        with socket.socket() as check:
            check.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            check.bind(('127.0.0.1',port))
