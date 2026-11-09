#!/usr/bin/env python3
"""Loopback observer matching a GET/POST/HEAD-only gateway; records rejected preflight."""
import argparse
import hashlib
import json
import ssl
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=18769)
parser.add_argument('--events', type=Path, required=True)
parser.add_argument('--https-port', type=int, default=18770)
parser.add_argument('--cert', type=Path)
parser.add_argument('--key', type=Path)
args = parser.parse_args()
if bool(args.cert) != bool(args.key):
    parser.error('--cert and --key must be supplied together')
args.events.parent.mkdir(parents=True, exist_ok=True)
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def serve(self):
        parts = urlsplit(self.path)
        query = parse_qs(parts.query)
        length = int(self.headers.get('Content-Length', '0'))
        if length > 4096:
            self.send_error(413)
            return
        body = self.rfile.read(length)
        origin = self.headers.get('Origin')
        allowed = origin in {'null', 'file://'}
        policy = parts.path.rsplit('/', 1)[-1]
        cors = allowed and policy in {'allow', 'auth'}
        status = 405 if self.command == 'OPTIONS' else 412 if policy == 'auth' else 200
        response = b'' if self.command == 'OPTIONS' else json.dumps({'observedOrigin': origin,
            'method': self.command, 'bodySHA256': hashlib.sha256(body).hexdigest(),
            'receivedSyntheticToken': self.headers.get('X-Probe-Token') == 'synthetic-probe-not-a-user-token',
            'message': 'synthetic-auth-required' if status == 412 else 'synthetic-echo'}).encode()
        row = {'utc': datetime.now(timezone.utc).isoformat(), 'method': self.command,
            'protocol': 'https' if isinstance(self.connection, ssl.SSLSocket) else 'http',
            'path': parts.path, 'query': query, 'origin': origin, 'status': status, 'corsReturned': cors,
            'headerNames': sorted(k.lower() for k in self.headers),
            'requestedMethod': self.headers.get('Access-Control-Request-Method'),
            'requestedHeaders': self.headers.get('Access-Control-Request-Headers'),
            'bodyBytes': len(body), 'bodySHA256': hashlib.sha256(body).hexdigest(),
            'syntheticTokenReceived': self.headers.get('X-Probe-Token') == 'synthetic-probe-not-a-user-token',
            'syntheticHeadersMatch': all(self.headers.get(name) == value for name, value in {
                'Content-Type': 'application/json', 'X-Probe-Token': 'synthetic-probe-not-a-user-token',
                'X-Probe-Session': 'synthetic-probe', 'X-Probe-Version': '0.0.0-probe',
                'X-Probe-Platform': 'ios', 'X-Probe-Run': 'offline-origin-probe', 'X-Probe-Container': 'H5'}.items()),
            'cookiePresent': bool(self.headers.get('Cookie'))}
        with lock:
            with args.events.open('a') as output: output.write(json.dumps(row) + '\n')
        print(json.dumps(row), flush=True)
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.send_header('Cache-Control', 'no-store')
        if cors and self.command != 'OPTIONS':
            self.send_header('Access-Control-Allow-Origin', origin)
            self.send_header('Vary', 'Origin')
        self.end_headers()
        try:
            if self.command != 'HEAD': self.wfile.write(response)
        except (BrokenPipeError, ConnectionResetError): pass
    do_GET = do_POST = do_HEAD = do_OPTIONS = serve

if args.cert:
    secure = ThreadingHTTPServer(('127.0.0.1', args.https_port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    secure.socket = context.wrap_socket(secure.socket, server_side=True)
    threading.Thread(target=secure.serve_forever, daemon=True).start()
ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
