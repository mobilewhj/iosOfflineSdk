#!/usr/bin/env python3
"""仅回环的隔离托管验证源，记录合成事件，不接触业务服务或凭据。"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import argparse
import hashlib
import json
import threading
import time
import select
import socket
import base64
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
LOCK = threading.Lock()
STATE = {'version': 'A', 'disabled': False, 'failure': False, 'wrongSHA': False, 'configDelay': 0, 'config_requests': 0}
ARGS = None

def allowed_origins():
    return {'null', 'http://127.0.0.1:' + str(ARGS.port), 'offline-managed://127.0.0.1:' + str(ARGS.port)}

def event(kind, **fields):
    row = dict(event=kind, monotonic=time.monotonic(), utc=datetime.now(timezone.utc).isoformat(), **fields)
    line = json.dumps(row, ensure_ascii=False)
    with LOCK:
        with open(ARGS.events, 'a', encoding='utf-8') as output:
            output.write(line + '\n')
    print(line, flush=True)

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def body(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length > 4096:
            raise ValueError('synthetic-request-too-large')
        return self.rfile.read(length)
    def cors(self):
        origin = self.headers.get('Origin')
        allowed = allowed_origins()
        if origin in allowed:
            self.send_header('Access-Control-Allow-Origin', origin)
            self.send_header('Vary', 'Origin')
        return origin if origin in allowed else 'unexpected'
    def send(self, content, status=200, mime='application/json', extra=None):
        if isinstance(content, str):
            content = content.encode()
        self.send_response(status); self.send_header('Content-Type', mime)
        self.send_header('Cache-Control', 'no-store'); self.send_header('Content-Length', str(len(content)))
        self.cors()
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(content)
        except (BrokenPipeError, ConnectionResetError):
            event('response-cancelled', endpoint=urlsplit(self.path).path)
    def do_OPTIONS(self):
        if urlsplit(self.path).path != '/api/echo':
            self.send('{}', 404); return
        names = [value.strip().lower() for value in self.headers.get('Access-Control-Request-Headers', '').split(',') if value]
        event('api-preflight', origin=self.headers.get('Origin') if self.headers.get('Origin') in allowed_origins() else 'unexpected', method=self.headers.get('Access-Control-Request-Method'), header_names=names)
        self.send('', 204, extra={'Access-Control-Allow-Methods':'POST', 'Access-Control-Allow-Headers':'Content-Type, X-AUTH-TOKEN, X-APP_VERSION, X-APP-PLAT, CONTAINER, X-THIRD-TOKEN, CHANNEL'})
    def do_POST(self):
        path = urlsplit(self.path).path
        try:
            body = json.loads(self.body() or '{}')
        except (ValueError, json.JSONDecodeError):
            self.send('{}', 400); return
        if path == '/control':
            with LOCK:
                if body.get('version') in {'A', 'B'}:
                    STATE['version'] = body['version']
                if 'disabled' in body:
                    STATE['disabled'] = bool(body['disabled'])
                if 'failure' in body:
                    STATE['failure'] = bool(body['failure'])
                if 'wrongSHA' in body:
                    STATE['wrongSHA'] = bool(body['wrongSHA'])
                if 'configDelay' in body:
                    STATE['configDelay'] = max(0, min(15, float(body['configDelay'])))
                snapshot = dict(STATE)
            event('control', version=snapshot['version'], disabled=snapshot['disabled'], failure=snapshot['failure'], wrongSHA=snapshot['wrongSHA'], config_delay=snapshot['configDelay'])
            self.send(json.dumps(snapshot)); return
        if path != '/api/echo':
            self.send('{}', 404); return
        expected = ['X-AUTH-TOKEN', 'X-APP_VERSION', 'X-APP-PLAT', 'CONTAINER', 'X-THIRD-TOKEN', 'CHANNEL']
        observed = [name for name in expected if self.headers.get(name)]
        container = 'H5' if self.headers.get('CONTAINER') == 'H5' else 'unexpected'
        accepted = len(observed) == len(expected) and container == 'H5' and body.get('requestId') == 'isolated-test'
        event('api-post', origin=self.headers.get('Origin') if self.headers.get('Origin') in allowed_origins() else 'unexpected', header_names=observed, container=container, accepted=accepted, body_shape_valid=body.get('requestId') == 'isolated-test')
        self.send(json.dumps({'accepted':accepted, 'requestId':'isolated-test'}))
    def do_GET(self):
        parts = urlsplit(self.path); path = parts.path
        with LOCK:
            snapshot = dict(STATE)
            if path == '/configuration':
                STATE['config_requests'] += 1
                snapshot['config_requests'] = STATE['config_requests']
        case = parse_qs(parts.query).get('case', [''])[0]
        case = case if case in {'initial','missing','redirect','range','fixed-after-B','after-disable','reopen-A','read-failure','cancel-probe','background-disabled','background-B'} else ''
        if path == '/configuration':
            event('configuration', ordinal=snapshot['config_requests'], version=snapshot['version'], disabled=snapshot['disabled'], failure=snapshot['failure'], wrongSHA=snapshot['wrongSHA'])
            # 固定合成响应快照；普通后台后返回值不被后续 control 偷换。
            time.sleep(snapshot['configDelay'])
            if snapshot['failure']:
                self.send('{"test_failure":true}', 503); return
            if snapshot['disabled']:
                # 关闭不要求合法目标字段，验证 SDK 的优先级。
                self.send('{"enabled":false,"version":"bad","packageURL":"invalid","sha256":"bad"}'); return
            info = json.loads((ROOT / 'Demo/ManagedPackageManifest.json').read_text())[snapshot['version']]
            self.send(json.dumps({'enabled':True, 'version':info['version'], 'packageURL':'http://127.0.0.1:' + str(ARGS.port) + '/packages/' + snapshot['version'] + '.zip', 'sha256':'0' * 64 if snapshot['wrongSHA'] else info['sha256']})); return
        if path in {'/packages/A.zip', '/packages/B.zip'}:
            label = path[-5]
            payload = (ROOT / 'Demo/Resources' / ('managed-' + label + '.zip')).read_bytes()
            event('package-start', package=label, bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
            chunked = ARGS.chunked_a and label == 'A'
            self.send_response(200); self.send_header('Content-Type', 'application/zip')
            self.send_header('Transfer-Encoding' if chunked else 'Content-Length', 'chunked' if chunked else str(len(payload)))
            self.send_header('Cache-Control', 'no-store'); self.end_headers()
            chunks = 40; delay = (ARGS.a_delay if label == 'A' else ARGS.b_delay) / chunks
            size = max(1, (len(payload) + chunks - 1) // chunks)
            try:
                for offset in range(0, len(payload), size):
                    chunk = payload[offset:offset + size]
                    if chunked:
                        self.wfile.write(format(len(chunk), 'x').encode() + b'\r\n' + chunk + b'\r\n')
                    else:
                        self.wfile.write(chunk)
                    self.wfile.flush(); time.sleep(delay)
                if chunked:
                    self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
                event('package-finished', package=label)
            except (BrokenPipeError, ConnectionResetError):
                event('package-cancelled', package=label)
            return
        if path == '/app/slow.js':
            event('slow-script-start', case=case)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                ready, _, _ = select.select([self.connection], [], [], 0.05)
                if ready and self.connection.recv(1, socket.MSG_PEEK) == b'':
                    event('slow-script-connection-cancelled', case=case)
                    self.close_connection = True
                    return
            self.send('window.__SLOW_EXECUTED__=true;', mime='text/javascript')
            event('slow-script-response-sent', case=case)
            return
        if path == '/app/missing.js':
            event('static-fallback', resource='missing.js', case=case)
            self.send("window.__MISSING_SOURCE__='network';", mime='text/javascript'); return
        if path == '/app/redirect.js':
            event('static-redirect', case=case)
            self.send('', 302, mime='text/javascript', extra={'Location':'/app/redirect-target.js'}); return
        if path == '/app/redirect-target.js':
            event('static-redirect-target')
            self.send("window.__REDIRECT_SOURCE__='network-redirect';", mime='text/javascript'); return
        if path == '/app/css/start.css':
            event('redirect-css-request', path=path)
            self.send('', 302, mime='text/css', extra={'Location':'/app/theme/style.css'}); return
        if path == '/app/theme/style.css':
            event('redirect-css-request', path=path)
            self.send('#redirect-probe { color:rgb(17,34,51); width:24px; height:24px; background-image:url(icon.png); }', mime='text/css'); return
        if path in {'/app/theme/icon.png', '/app/css/icon.png'}:
            event('redirect-icon-request', path=path, expected=path == '/app/theme/icon.png')
            if path != '/app/theme/icon.png':
                self.send('{}', 404); return
            # 固定 1×1 合成 PNG，只有重定向最终目录中存在。
            self.send(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg=='), mime='image/png'); return
        if path == '/app/range.txt':
            observed = self.headers.get('Range') == 'bytes=0-3'
            event('static-range', range_present=observed, case=case)
            self.send('0123' if observed else '0123456789', 206 if observed else 200, mime='text/plain', extra={'Content-Range':'bytes 0-3/10'} if observed else None); return
        if path.startswith('/app/'):
            relative = path[len('/app/'):]
            if relative not in {'index.html','style.css','app.js','payload.js','payload.json'}:
                self.send('{}', 404); return
            event('online-static', resource=relative, package=snapshot['version'], case=case)
            payload = (ROOT / 'Demo/ManagedWeb' / snapshot['version'] / relative).read_bytes()
            mime = {'html':'text/html','css':'text/css','js':'text/javascript','json':'application/json'}[relative.rsplit('.', 1)[-1]]
            self.send(payload, mime=mime); return
        self.send('{}', 404)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18765)
    parser.add_argument('--events', required=True)
    parser.add_argument('--a-delay', type=float, default=2)
    parser.add_argument('--b-delay', type=float, default=5)
    parser.add_argument('--chunked-a', action='store_true', help='首包未知总量进度')
    ARGS = parser.parse_args()
    Path(ARGS.events).parent.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', ARGS.port), Handler)
    event('server-started', port=ARGS.port)
    server.serve_forever()
