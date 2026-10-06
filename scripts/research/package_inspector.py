#!/usr/bin/env python3
"""Wrap an already-built inspector in a local .app bundle; do not launch or install it."""
import argparse
from pathlib import Path
import plistlib
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path, help='Built SystemOneInspector executable')
parser.add_argument('output', type=Path, help='New .app path in an ignored build or temporary directory')
parser.add_argument('--name', default='System One Inspector')
parser.add_argument('--bundle-id', default='com.example.system-one-inspector')
args = parser.parse_args()
if args.output.suffix != '.app' or args.output.exists():
    parser.error('Output must be a new .app path; existing bundles are not overwritten')
if not args.binary.is_file():
    parser.error('Inspector executable not found; build it first')
contents = args.output / 'Contents'
(contents / 'MacOS').mkdir(parents=True)
shutil.copy2(args.binary, contents / 'MacOS/SystemOneInspector')
(contents / 'MacOS/SystemOneInspector').chmod(0o755)
for resource in args.binary.parent.glob('*.bundle'):
    destination = contents / 'Resources' / resource.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(resource, destination)

(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'SystemOneInspector',
    'CFBundleIdentifier': args.bundle_id,
    'CFBundleName': args.name,
    'CFBundleDisplayName': args.name,
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '13.0',
    'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication',
}))
print(args.output.resolve())
