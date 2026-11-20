#!/usr/bin/env python3
"""Verify the shipped archive without launching its executable."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--bundle', type=Path, required=True)
parser.add_argument('--zip', type=Path, required=True)
parser.add_argument('--testing-binary', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert not args.output.exists()
args.output.mkdir(parents=True)
root = Path(__file__).resolve().parent.parent

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def command(*argv):
    result = subprocess.run(list(argv), capture_output=True, text=True, check=True)
    return result.stdout + result.stderr

version = (root / 'VERSION').read_text().strip()
readme = (root / 'README.md').read_text()
assert 'macOS 27 or later' in readme and 'arm64 only' in readme
marker = b'APPARATE_TEST_MODE'
assert marker in args.testing_binary.read_bytes(), 'Size comparator is not a testing executable'
with zipfile.ZipFile(args.zip) as archive:
    members = archive.namelist()
    assert len(set(members)) == len(members)
    assert all(name == 'Apparate.app/' or name.startswith('Apparate.app/') for name in members)
    assert all('..' not in Path(name).parts and '/Users/' not in name and '.DS_Store' not in name and not name.endswith('.log') for name in members)
    assert archive.testzip() is None
    (args.output / 'archive-members.txt').write_text('\n'.join(members) + '\n')
with tempfile.TemporaryDirectory(prefix='apparate-release-', dir='/private/tmp') as temporary:
    extraction = Path(temporary)
    command('ditto', '-x', '-k', str(args.zip), temporary)
    app = extraction / 'Apparate.app'
    binary = app / 'Contents/MacOS/Apparate'
    original = args.bundle / 'Contents/MacOS/Apparate'
    for item in app.rglob('*'):
        assert not item.is_symlink()
        if item.is_file(): assert item.read_bytes() == (args.bundle / item.relative_to(app)).read_bytes()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == info['CFBundleVersion'] == version
    assert info['LSMinimumSystemVersion'] == '27.0' and info['CFBundleIdentifier'] == 'local.apparate'
    assert info['CFBundleIconFile'] == 'AppIcon'
    for source in ['Resources/AppIcon.icns', 'THIRD_PARTY_NOTICES.txt', 'LICENSE']:
        assert digest(root / source) == digest(app / 'Contents/Resources' / Path(source).name)
    assert command('lipo', '-archs', str(binary)).strip() == 'arm64'
    load = command('otool', '-l', str(binary))
    assert re.search(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos 27\.0\s', load)
    command('codesign', '--verify', '--deep', '--strict', str(app))
    signing = command('codesign', '-d', '-r-', '--verbose=2', str(app))
    assert 'Signature=adhoc' in signing and 'designated => identifier "local.apparate"' in signing
    (args.output / 'signature.txt').write_text(signing.replace(str(extraction), '<extraction>'))
    strings = command('/usr/bin/strings', str(binary))
    symbols = command('nm', '-j', str(binary))
    forbidden = ['APPARATE_TEST', 'APPARATE_SHOW', 'APPARATE_PANEL_', 'APPARATE_SETTINGS_CHECK', 'APPARATE_PERFORMANCE',
                 'APPARATE_STAGE_PROBES', 'APPARATE_BARE_FIELD', 'APPARATE_DOT_ENTRIES', 'ApparateFixtures',
                 'TestProfile', 'PanelVerification', 'SettingsVerification', 'PerformanceVerification', 'FullPerformance',
                 'AppTestDiagnostics', 'TestEffects', 'FixtureLoginService', 'fixture:terminal', '/Fixture/', 'SyntheticFiles',
                 'Desk Notes', 'apparate-demo.png', '/Users/']
    assert not any(value in strings or value in symbols for value in forbidden), [v for v in forbidden if v in strings or v in symbols]
    result = {'result': 'Passed', 'version': version, 'minimum_macos': info['LSMinimumSystemVersion'], 'architecture': 'arm64',
              'zip_sha256': digest(args.zip), 'zip_bytes': args.zip.stat().st_size, 'app_sha256': digest(binary),
              'production_binary_bytes': binary.stat().st_size, 'testing_binary_bytes': args.testing_binary.stat().st_size,
              'testing_binary_sha256': digest(args.testing_binary), 'strict_deep_signature': True,
              'designated_requirement': 'identifier "local.apparate"', 'archive_content_matches_bundle': True,
              'forbidden_strings_and_symbols_absent': forbidden, 'app_launched': False}
    dimensions = struct.unpack('>II', (root / 'docs/assets/icon.png').read_bytes()[16:24]); assert dimensions == (1024, 1024)
    result['icon_dimensions'] = dimensions
result['extraction_removed'] = not extraction.exists()
for mode in [False, True]:
    env = dict(os.environ, APPARATE_BUILD_TESTING='1' if mode else '0')
    manifest = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], cwd=root, env=env))
    target = next(t for t in manifest['targets'] if t['name'] == 'Apparate')
    dependencies = [d['byName'][0] for d in target['dependencies']]
    assert dependencies == (['ApparateCore', 'ApparateFixtures'] if mode else ['ApparateCore'])
    assert len(target['exclude']) == (0 if mode else 6)
    (args.output / ('package-testing.json' if mode else 'package-production.json')).write_text(json.dumps(target, indent=2) + '\n')
result['app_dependency_graph_verified'] = True
(args.output / 'release.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
