#!/usr/bin/env python3
"""Hidden M6 driver. Never presents, captures, focuses, or posts global events."""
import argparse
import atexit
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('mode', choices=['pipeline', 'latency', 'full'])
parser.add_argument('--count', type=int, choices=[20000, 200000], default=20000)
parser.add_argument('--projects', action='store_true')
parser.add_argument('--bare', action='store_true')
parser.add_argument('--probes', action='store_true')
parser.add_argument('--delivery', choices=['task', 'dispatch'], default='task')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert not args.projects or args.mode == 'full'
assert not (args.bare or args.probes) or args.mode == 'latency'
assert not args.output.exists(), 'Keep each attempt in a fresh evidence directory'
args.output.mkdir(parents=True)
root = Path(__file__).resolve().parent.parent
binary = root / 'build/Apparate.app/Contents/MacOS/Apparate'
identity = {'app_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'mode': args.mode,
            'count': args.count, 'projects': args.projects, 'bare': args.bare, 'probes': args.probes,
            'delivery': args.delivery, 'start_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
(args.output / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
def cleanup_receipt():
    owned_home = globals().get('home')
    owned_process = globals().get('process')
    (args.output / 'cleanup.json').write_text(json.dumps({
        'owned_process_exited': owned_process is None or owned_process.poll() is not None,
        'owned_home_removed': owned_home is None or not owned_home.exists(),
        'projects_read_only': args.projects}) + '\n')
atexit.register(cleanup_receipt)
with tempfile.TemporaryDirectory(prefix='apparate-m6-') as temporary:
    home = Path(temporary)
    folders = []
    if args.mode == 'full':
        source = Path.home() / 'Projects' if args.projects else home / 'FixtureProjects'
        if not args.projects:
            source.mkdir()
            for group in range(500):
                (source / f'Project-{group:04d}').mkdir()
            names = ['README', 'Report', 'Config', 'Network', 'Calendar', 'Terminal', 'Archive', 'Notes', 'Search', 'Index', 'Café', 'Straße', '東京資料']
            for i in range(args.count - 501):
                (source / f'Project-{i % 500:04d}' / f'{names[(i * 17 + 31) % len(names)]}-{i:06d}.md').touch()
        folders = [{'path': str(source), 'depth': 10}]
    (home / 'config.json').write_text(json.dumps({'version': 1,
        'hotKey': {'keyCode': 111, 'modifiers': 6400, 'display': '⌃⌥⌘F12'}, 'folders': folders}))
    env = {k: v for k, v in os.environ.items() if not k.startswith('APPARATE_')}
    env.update(APPARATE_HOME=str(home), APPARATE_TEST_MODE='live-readonly' if args.mode == 'full' else 'fixtures',
               APPARATE_PANEL_COUNT=str(args.count), APPARATE_BARE_FIELD='1' if args.bare else '0',
               APPARATE_STAGE_PROBES='1' if args.probes else '0', APPARATE_PANEL_DELIVERY=args.delivery)
    for mode in (['prepare', 'full'] if args.mode == 'full' else [args.mode]):
        env['APPARATE_PERFORMANCE'] = mode
        receipt = home / 'diagnostics.json'
        receipt.unlink(missing_ok=True)
        process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        started = time.monotonic()
        try:
            stdout, stderr = process.communicate(timeout=600)
            if process.returncode != 0:
                diagnostic = stderr.decode(errors='replace').replace(str(home), '<fixture-home>').replace(str(root), '<repo>').replace(str(Path.home()), '<user-home>')
                (args.output / 'process-failure.log').write_text(diagnostic[:24000])
            assert process.returncode == 0, f'{mode}: process exit {process.returncode}'
            result = json.loads(receipt.read_text())
            result['elapsed_seconds'] = time.monotonic() - started
            result['stdout_bytes'] = len(stdout); result['stderr_bytes'] = len(stderr)
            for file in home.glob('*.csv'):
                shutil.copyfile(file, args.output / file.name)
            (args.output / f'{mode}.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
            assert result['result'] == 'Passed' and result['errors'] == 0, result
            assert result['visible_profile'] == 'none' and result['focus_guards_checked']
            assert all(result[k] == 0 for k in ['native_actions', 'native_hotkey_registrations', 'native_status_items', 'native_login_changes', 'protected_folder_probes', 'symbolichotkeys_writes'])
            if mode == 'full':
                assert result['loaded_from_disk'] and result['file_watch_healthy'] and result['catalog_watch_healthy']
                assert args.projects or result['file_count'] == args.count
            print(json.dumps({'mode': mode, 'result': result['result'], 'elapsed_seconds': result['elapsed_seconds']}), flush=True)
        except BaseException as error:
            (args.output / 'failure.json').write_text(json.dumps({'result': 'Failed', 'exception': type(error).__name__, 'phase': mode}) + '\n')
            raise
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=10)
            assert process.poll() is not None
assert not home.exists()
(args.output / 'cleanup.json').write_text(json.dumps({'owned_process_exited': True, 'owned_home_removed': True, 'projects_read_only': args.projects}) + '\n')
