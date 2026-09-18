#!/usr/bin/env python3
"""Small deterministic adversarial ZIPs; no production data or downloaded bundle."""
import json
import hashlib
import io
import struct
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1] / 'Tests/Fixtures'
root.mkdir(parents=True, exist_ok=True)
manifest = {}


def archive(name, entries, mutate=lambda b: b):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for path, contents in entries:
            info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = ((0o120777 if path == 'link' else 0o100644) << 16)
            z.writestr(info, contents)
    data = mutate(buffer.getvalue())
    (root / (name + '.zip')).write_bytes(data)
    manifest[name] = hashlib.sha256(data).hexdigest()


archive('root', [('index.html', '<html>version A</html>'), ('static/app.js', 'window.loaded=true;'), ('font.woff2', b'font')])
archive('dist', [('dist/index.html', '<html>version B</html>'), ('dist/static/app.js', 'window.loaded=true;')])
archive('traversal', [('index.html', 'ok'), ('../escaped.txt', 'escape')])
archive('absolute', [('index.html', 'ok'), ('/escaped.txt', 'escape')])
archive('symlink', [('index.html', 'ok'), ('link', '../outside')])
archive('duplicate', [('index.html', 'ok'), ('index.html', 'bad')])
archive('case_alias', [('index.html', 'ok'), ('INDEX.html', 'bad')])
archive('conflict', [('index.html', 'ok'), ('static', 'file'), ('static/a.js', 'bad')])
archive('empty', [('index.html', '')])
archive('missing', [('app.js', 'ok')])
archive('truncated', [('index.html', 'ok')], lambda b: b[:-15])


def corrupt_crc(data):
    b = bytearray(data)
    offset = b.index(b'PK\x01\x02')
    b[offset + 16] ^= 0xFF
    return bytes(b)


def wrong_count(data):
    b = bytearray(data)
    offset = b.rindex(b'PK\x05\x06')
    struct.pack_into('<HH', b, offset + 8, 2, 2)
    return bytes(b)


archive('crc', [('index.html', 'ok')], corrupt_crc)
archive('wrong_count', [('index.html', 'ok')], wrong_count)
archive('oversized', [('index.html', b'x' * (64 * 1024 * 1024 + 1))])
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
