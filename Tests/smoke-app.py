#!/usr/bin/env python3
"""Isolated app driver. Native effects are disabled by the explicit app test profile."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--fixture-app', action='store_true')
parser.add_argument('--file-source', choices=['fixture', 'projects'])
parser.add_argument('--mode', choices=['fixtures', 'live-readonly'], default='fixtures')
parser.add_argument('--show', choices=['panel', 'setup'])
parser.add_argument('--seconds', type=float, default=2)
parser.add_argument('--query', default='term')
parser.add_argument('--action-open', action='store_true')
parser.add_argument('--output', type=Path)
parser.add_argument('--runs', type=int, default=1, help='Reuse the isolated cache across 1–3 hidden read-only runs')
args = parser.parse_args()
assert 1 <= args.seconds <= 90
assert 1 <= args.runs <= 3 and (args.runs == 1 or args.mode == 'live-readonly')
assert not args.show or args.mode == 'fixtures'
assert args.file_source != 'projects' or args.mode == 'live-readonly'
assert not args.fixture_app or args.file_source == 'fixture'
assert not args.action_open or args.show == 'panel'
root = Path(__file__).resolve().parent.parent
binary = root / 'build/Apparate.app/Contents/MacOS/Apparate'
assert binary.is_file(), 'Run ./build.sh first'
with tempfile.TemporaryDirectory(prefix='apparate-m2-app-') as directory:
    home = Path(directory)
    folders = []
    if args.file_source == 'fixture':
        source = home / 'FixtureProjects'
        source.mkdir()
        (source / 'fixture-ledger.txt').write_text('fixture')
        (source / 'Nested').mkdir()
        (source / 'Nested' / 'fixture-report.md').write_text('fixture')
        if args.fixture_app:
            app_contents = source / 'FixtureEditor.app' / 'Contents'
            app_contents.mkdir(parents=True)
            (app_contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'fixture.editor', 'CFBundlePackageType': 'APPL', 'CFBundleDisplayName': 'Fixture Editor', 'CFBundleName': 'FixtureEditor'}))
        folders = [{'path': str(source), 'depth': 10}]
    elif args.file_source == 'projects':
        folders = [{'path': str(Path.home() / 'Projects'), 'depth': 10}]
    # Seed BEFORE launch. APPARATE_HOME alone does not prevent default shortcut registration.
    (home / 'config.json').write_text(json.dumps({
        'version': 1, 'hotKey': {'keyCode': 111, 'modifiers': 6400, 'display': '⌃⌥⌘F12'},
        'folders': folders
    }))
    env = {k: v for k, v in os.environ.items() if not k.startswith('APPARATE_')}
    env.update(APPARATE_HOME=directory, APPARATE_TEST_MODE=args.mode,
               APPARATE_TEST_SECONDS=str(args.seconds), APPARATE_TEST_QUERY=args.query)
    if args.show:
        env['APPARATE_SHOW'] = args.show
    if args.action_open:
        env['APPARATE_TEST_ACTION'] = 'open'
    results = []
    for run in range(args.runs):
        process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, stderr = process.communicate(timeout=args.seconds + 65)
            assert process.returncode == 0, 'App did not exit normally'
            receipt = home / 'diagnostics.json'
            assert receipt.is_file(), 'App did not write its test receipt'
            result = json.loads(receipt.read_text())
            assert result['ready'] and result['errors'] == 0, result
            assert result['native_actions'] == result['native_hotkey_registrations'] == result['protected_folder_probes'] == 0
            assert result['fake_registrations'] == 1
            assert result['fake_actions'] == (1 if args.action_open else 0)
            if args.file_source:
                assert result['file_count'] > 0 and result['file_watch_healthy']
                if run > 0:
                    assert result['file_loaded_from_disk']
            if args.file_source == 'fixture':
                assert result['file_count'] == (5 if args.fixture_app else 4)
                assert result['discovered_app_count'] == (1 if args.fixture_app else 0)
                if args.action_open and args.query == 'fixture-ledger':
                    assert result['fake_url_opens'] == 1
                if args.action_open and args.fixture_app and args.query == 'Fixture Editor':
                    assert result['fake_application_opens'] == 1
            if args.show:
                assert result['capture_written'] and (home / (args.show + '.png')).is_file()
            if args.mode == 'live-readonly':
                assert result['app_count'] > 0 and result['settings_count'] > 0 and result['watch_healthy']
            if args.mode == 'live-readonly':
                cached = json.loads((home / 'settings-cache.json').read_text())
                assert cached['version'] == 2
                modern = [r for r in cached['records'] if r['bundle'] == 'com.apple.Date-Time-Settings.extension']
                legacy = [r for r in cached['records'] if r['bundle'] == 'com.apple.preference.datetime']
                panes = [r for r in modern if r.get('anchor') is None]
                assert len(panes) == 1 and len(modern) > 1 and not legacy, 'Date & Time target catalog is incorrect'
                result['date_time_panes'] = len(panes)
                result['date_time_records'] = len(modern)
                result['legacy_date_time_targets'] = len(legacy)
            result['result'] = 'Passed'
            result['stdout_bytes'] = len(stdout)
            result['stderr_bytes'] = len(stderr)
            if run > 0:
                assert result['first_settings_cache_hit'], 'Persisted settings cache did not load'
            results.append(result)
            if args.output:
                args.output.mkdir(parents=True, exist_ok=True)
                for picture in home.glob('*.png'):
                    shutil.copyfile(picture, args.output / picture.name)
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
result = results[-1]
if len(results) > 1:
    result['previous_runs'] = results[:-1]
result['cleanup'] = 'Owned process exited; test-created APPARATE_HOME removed'
if args.output:
    (args.output / 'receipt.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
print(json.dumps(result, indent=2, sort_keys=True))
