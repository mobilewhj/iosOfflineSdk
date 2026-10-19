#!/usr/bin/env python3
"""Small deterministic adversarial ZIPs; no production data or downloaded bundle."""
import json
import hashlib
import io
import struct
import zipfile
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1] / 'Tests/Fixtures'
root.mkdir(parents=True, exist_ok=True)
manifest = {}
additions_only = '--additions-only' in sys.argv
legacy = json.loads((root / 'manifest.json').read_text()) if (root / 'manifest.json').exists() else {}


def archive(name, entries, mutate=lambda b: b, compression=zipfile.ZIP_DEFLATED):
    if additions_only and name in legacy:
        manifest[name] = legacy[name]
        return
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for path, contents in entries:
            info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = compression
            info.external_attr = ((0o120777 if path == 'link' else 0o40755 if path.endswith('/') else 0o100644) << 16)
            z.writestr(info, contents)
    data = mutate(buffer.getvalue())
    destination = root / (name + '.zip')
    if destination.exists():
        if destination.read_bytes() != data:
            raise RuntimeError(f'保留既有夹具，拒绝覆盖 {destination}')
    else:
        with destination.open('xb') as output:
            output.write(data)
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
if not (root / 'manifest.json').exists():
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
elif manifest != legacy:
    raise RuntimeError('旧夹具身份不匹配，拒绝覆盖 manifest.json')

# 本轮新增样本单列身份，旧 ZIP/manifest/历史证据均不覆盖。
manifest = {}
archive('managed_directory_valid', [('index.html', 'ok'), ('static/', b''), ('static/a.js', 'ok')])
archive('managed_directory_payload', [('index.html', 'ok'), ('static/', b'payload')])


def mutate_directory(data, hide_payload=False):
    b = bytearray(data)
    offset = 0
    while True:
        offset = b.index(b'PK\x03\x04', offset)
        name_length, extra_length = struct.unpack_from('<HH', b, offset + 26)
        name = b[offset + 30:offset + 30 + name_length]
        if name.endswith(b'/'):
            struct.pack_into('<I', b, offset + 22, 0 if hide_payload else 1)
            if hide_payload:
                struct.pack_into('<I', b, offset + 14, 0)
            break
        offset += 30 + name_length + extra_length + struct.unpack_from('<I', b, offset + 18)[0]
    if hide_payload:
        offset = b.index(b'PK\x01\x02')
        while True:
            name_length, extra_length, comment_length = struct.unpack_from('<HHH', b, offset + 28)
            name = b[offset + 46:offset + 46 + name_length]
            if name.endswith(b'/'):
                struct.pack_into('<II', b, offset + 16, 0, struct.unpack_from('<I', b, offset + 20)[0])
                struct.pack_into('<I', b, offset + 24, 0)
                break
            offset += 46 + name_length + extra_length + comment_length
    return bytes(b)


archive('managed_directory_inconsistent', [('index.html', 'ok'), ('static/', b'')], mutate_directory)
archive('managed_directory_hidden_payload', [('index.html', 'ok'), ('static/', b'payload')], lambda b: mutate_directory(b, True))
archive('managed_entry_count_limit', [('index.html', 'ok')] + [(f'entries/{i}', '') for i in range(10_000)])


def declare_large_sizes(data):
    b = bytearray(data)
    offset = 0
    for _ in range(5):
        offset = b.index(b'PK\x03\x04', offset)
        struct.pack_into('<I', b, offset + 22, 64 * 1024 * 1024)
        offset += 30 + sum(struct.unpack_from('<HH', b, offset + 26)) + struct.unpack_from('<I', b, offset + 18)[0]
    offset = b.index(b'PK\x01\x02')
    for _ in range(5):
        struct.pack_into('<I', b, offset + 24, 64 * 1024 * 1024)
        offset += 46 + sum(struct.unpack_from('<HHH', b, offset + 28))
    return bytes(b)


archive('managed_total_size_limit', [(f'{i}.js', 'x') for i in range(5)], declare_large_sizes)


def undercount(data):
    b = bytearray(data)
    struct.pack_into('<HH', b, b.rindex(b'PK\x05\x06') + 8, 1, 1)
    return bytes(b)


archive('managed_central_undercount', [('index.html', 'ok'), ('other.js', 'ok')], undercount)
addition_manifest = root / 'managed-manifest.json'
text = json.dumps(manifest, indent=2) + '\n'
if addition_manifest.exists():
    if addition_manifest.read_text() != text:
        raise RuntimeError('新增夹具身份已存在，拒绝覆盖')
else:
    with addition_manifest.open('x') as output:
        output.write(text)

manifest = {}
archive('managed_directory_stored', [('index.html', 'ok'), ('static/', b'')], compression=zipfile.ZIP_STORED)
stored_manifest = root / 'managed-directory-stored-manifest.json'
stored_text = json.dumps(manifest, indent=2) + '\n'
if stored_manifest.exists():
    if stored_manifest.read_text() != stored_text:
        raise RuntimeError('stored 目录夹具身份已存在，拒绝覆盖')
else:
    with stored_manifest.open('x') as output:
        output.write(stored_text)

# Valid managed-capacity evidence: compressed fixture, real data/CRC, no declared-size mutation.
manifest = {}
large_payload = b'x' * (52 * 1024 * 1024)
archive('managed_large_total_valid', [('index.html', 'ok')] + [(f'assets/{i}.bin', large_payload) for i in range(5)])
large_manifest = root / 'managed-large-valid-manifest.json'
large_text = json.dumps({'sha256': manifest, 'expanded_bytes': 5 * len(large_payload) + 2, 'regular_files': 6}, indent=2) + '\n'
if large_manifest.exists():
    if large_manifest.read_text() != large_text:
        raise RuntimeError('Existing valid large fixture identity differs; refusing overwrite')
else:
    large_manifest.write_text(large_text)
