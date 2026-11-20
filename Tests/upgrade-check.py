#!/usr/bin/env python3
"""Compare baseline-written stores with current production Core, without launching an app."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True, help='Current production-mode ApparateUpgradeCheck executable')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert args.binary.is_file() and not args.output.exists()
args.output.mkdir(parents=True)
root = Path(__file__).resolve().parent.parent
baseline = '9194cfdfb9d2f2721e0697c4b557770c88f12eb3'
with tempfile.TemporaryDirectory(prefix='apparate-upgrade-', dir='/private/tmp') as temporary:
    owned = Path(temporary)
    baseline_root = owned / 'baseline'
    baseline_root.mkdir()
    archive = owned / 'baseline.tar'
    with archive.open('wb') as stream:
        subprocess.run(['git', 'archive', baseline, 'Sources/ApparateCore'], cwd=root, stdout=stream, check=True)
    subprocess.run(['tar', '-xf', str(archive), '-C', str(baseline_root)], check=True)
    (baseline_root / 'Package.swift').write_text('''// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "Apparate", platforms: [.macOS(.v27)], targets: [
 .target(name: "ApparateCore", linkerSettings: [.linkedLibrary("sqlite3")]),
 .executableTarget(name: "ApparateUpgradeCheck", dependencies: ["ApparateCore"], path: "UpgradeCheck")
])
''')
    shutil.copytree(root / 'Tests/UpgradeCheck', baseline_root / 'UpgradeCheck')
    with (args.output / 'baseline-build.log').open('w') as log:
        subprocess.run(['swift', 'build', '--package-path', str(baseline_root), '-c', 'release', '--product', 'ApparateUpgradeCheck'], stdout=log, stderr=subprocess.STDOUT, check=True)
    bin_path = subprocess.check_output(['swift', 'build', '--package-path', str(baseline_root), '-c', 'release', '--show-bin-path'], text=True).strip()
    old_binary = Path(bin_path) / 'ApparateUpgradeCheck'
    data, fixture = owned / 'data', owned / 'FixtureProjects'
    for mode, binary in [('seed', old_binary), ('check', args.binary.resolve())]:
        result = subprocess.run([str(binary), mode, str(data), str(fixture), str((args.output / (mode + '.json')).resolve())], capture_output=True, timeout=20)
        assert result.returncode == 0 and not result.stderr, result.stderr.decode(errors='replace')
    seed = json.loads((args.output / 'seed.json').read_text())
    check = json.loads((args.output / 'check.json').read_text())
    fields = ['config_sha256', 'count', 'revision', 'last_update', 'search_names', 'usage_count', 'open_with', 'skip_hidden']
    assert all(seed[key] == check[key] for key in fields)
    assert check['loaded_from_disk'] and check['completed_scans'] == 0
    evidence = {'result': 'Passed', 'baseline_revision': baseline, 'baseline_sha256': hashlib.sha256(old_binary.read_bytes()).hexdigest(),
                'candidate_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(), 'matching_fields': fields,
                'harness_sha256': hashlib.sha256((root / 'Tests/UpgradeCheck/UpgradeCheck.swift').read_bytes()).hexdigest(),
                'scope': 'Production Core cache/config/history compatibility; no application launch or native effects',
                'all_processes_exited': True}
evidence['owned_home_removed'] = not owned.exists()
(args.output / 'comparison.json').write_text(json.dumps(evidence, indent=2) + '\n')
print(json.dumps(evidence, indent=2))
