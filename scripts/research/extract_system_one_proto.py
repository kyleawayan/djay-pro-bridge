#!/usr/bin/env python3
"""Read an installed djay app and export its embedded protocol into a private directory outside Git."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from export_proto_descriptor import export_bytes
from summarize_probe import fields


def value(items, number):
    return next((v for n, wire, v in items if n == number), None)


def find_schema(binary):
    prefix = b'remote_host_screen_service_'
    cursor = 0
    candidates = {}
    while True:
        offset = binary.find(prefix, cursor)
        if offset < 0:
            break
        cursor = offset + len(prefix)
        start = offset - 2
        if start < 0 or binary[start] != 0x0a:
            continue
        end = binary.find(b'\x62\x06proto3', cursor, min(len(binary), start + 1_048_576))
        if end < 0:
            continue
        data = binary[start:end + 8]
        try:
            descriptor = fields(data)
            filename = value(descriptor, 1)
            if not isinstance(filename, bytes) or not filename.startswith(prefix) or not filename.endswith(b'.proto'):
                continue
            if value(descriptor, 2) != b'remotehostscreen.v1' or value(descriptor, 12) != b'proto3':
                continue
            messages = [v for n, wire, v in descriptor if n == 4 and wire == 2]
            if not any(value(fields(message), 1) == b'HybridModeMessage' for message in messages):
                continue
        except (ValueError, IndexError, TypeError):
            continue
        digest = hashlib.sha256(data).hexdigest()
        candidates.setdefault(digest, {'data': data, 'offsets': []})['offsets'].append(start)
    if not candidates:
        raise ValueError('No readable matching descriptor found. This is inconclusive for other app versions; no decryption or runtime inspection is attempted.')
    if len(candidates) != 1:
        raise ValueError('Multiple distinct protocol descriptors found; inspect the architecture-specific evidence before choosing one.')
    return next(iter(candidates.values()))


def discover_app():
    matches = []
    for root in (Path('/Applications'), Path.home() / 'Applications'):
        if not root.is_dir():
            continue
        for app in root.glob('*.app'):
            try:
                info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            except (OSError, ValueError, plistlib.InvalidFileException):
                continue
            if str(info.get('CFBundleIdentifier', '')).startswith('com.algoriddim.djay'):
                matches.append(app)
    if len(matches) != 1:
        raise ValueError('Pass the exact djay .app path; discovery did not identify one unique application.')
    return matches[0]


def check_destination(destination):
    destination = destination.resolve()
    if destination.exists() and (not destination.is_dir() or any(destination.iterdir())):
        raise ValueError('Output must be a new or empty directory; existing exports are not overwritten.')
    for parent in (destination, *destination.parents):
        if (parent / '.git').exists():
            raise ValueError('Output must be outside Git. Omit --output to use the system temporary directory.')
    return destination


def extract(app, destination, generate_swift=False):
    app = app.resolve(strict=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    name = info.get('CFBundleExecutable')
    if not isinstance(name, str) or Path(name).name != name:
        raise ValueError('Invalid CFBundleExecutable')
    executable = (app / 'Contents/MacOS' / name).resolve(strict=True)
    if not executable.is_relative_to(app):
        raise ValueError('Executable resolves outside the app bundle')
    tools = {tool: shutil.which(tool) for tool in ('protoc', 'protoc-gen-swift')}
    if generate_swift and not all(tools.values()):
        raise ValueError('--swift requires already-installed protoc and protoc-gen-swift. This script never installs tools.')
    destination = check_destination(destination)
    binary = executable.read_bytes()
    found = find_schema(binary)
    export_bytes(found['data'], destination)
    descriptor = fields(found['data'])
    filename = value(descriptor, 1).decode('utf-8')
    if generate_swift:
        subprocess.run([tools['protoc'], '--descriptor_set_in=' + str(destination / 'original.descriptorset.pb'),
                        '--plugin=protoc-gen-swift=' + tools['protoc-gen-swift'],
                        '--swift_out=Visibility=Public:' + str(destination), filename], check=True)
    metadata = {
        'app_version': info.get('CFBundleShortVersionString'),
        'app_build': info.get('CFBundleVersion'),
        'executable_sha256': hashlib.sha256(binary).hexdigest(),
        'descriptor_sha256': hashlib.sha256(found['data']).hexdigest(),
        'descriptor_file_offsets': [hex(offset) for offset in found['offsets']],
        'protocol_filename': filename,
        'swift_generated': generate_swift,
        'note': 'Reconstructed source lacks original comments/formatting. Full schema and generated types are local artifacts, not repository inputs.'
    }
    (destination / 'extraction.json').write_text(json.dumps(metadata, indent=2) + '\n')
    destination.chmod(0o700)
    for path in destination.iterdir():
        if path.is_file():
            path.chmod(0o600)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', nargs='?', type=Path, help='Exact .app path; otherwise inspect standard application locations')
    parser.add_argument('--output', type=Path, help='New/empty directory outside Git; default is a private temporary directory')
    parser.add_argument('--swift', action='store_true', help='Also generate local Swift types using existing tools; never needed to build the debugger')
    args = parser.parse_args()
    try:
        app = args.app or discover_app()
        destination = args.output or Path(tempfile.mkdtemp(prefix='djay-protocol-'))
        result = extract(app, destination, args.swift)
        print('Local exports: ' + str(result))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Extraction failed: ' + str(error) + '\n')
