#!/usr/bin/env python3
"""Read-only M7 artifact/evidence assertions; never starts an app."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess

root = Path(__file__).resolve().parents[4]
base = Path(__file__).resolve().parent
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read(name): return json.loads((base / name).read_text())
manifest = read('source-manifest.json')
for name, expected in manifest.items():
    assert digest(root / name) == expected, name
assert not subprocess.check_output(['git', 'diff', 'b14f02c', '--', 'Sources/ApparateCore'], cwd=root)
artifact, identity = read('artifact/release.json'), read('build-identity.json')
production = root / 'build/Apparate.app'
testing = root / identity['bundle']
for bundle, sha, size in [(production, artifact['app_sha256'], artifact['production_binary_bytes']),
                          (testing, identity['app_sha256'], artifact['testing_binary_bytes'])]:
    binary = bundle / 'Contents/MacOS/Apparate'
    assert digest(binary) == sha and binary.stat().st_size == size
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], capture_output=True, check=True)
    assert digest(bundle / 'Contents/Resources/AppIcon.icns') == digest(root / 'Resources/AppIcon.icns')
assert artifact['testing_binary_sha256'] == identity['app_sha256']
archive = root / 'build/Apparate.zip'
assert digest(archive) == artifact['zip_sha256'] and archive.stat().st_size == artifact['zip_bytes']
assert artifact['result'] == 'Passed' and artifact['strict_deep_signature'] and artifact['extraction_removed']
assert artifact['archive_content_matches_bundle'] and artifact['app_dependency_graph_verified']
assert not artifact['app_launched']
assert len(read('artifact/package-production.json')['exclude']) == 6
assert 'APPARATE_TESTING' in str(read('artifact/package-testing.json')['settings'])
for name in ['debug-tests.log', 'release-tests.log', 'production-core-tests.log']:
    assert (base / name).read_text().strip().endswith('RESULT 134 passed; 0 failed')
for folder, name in [('panel', 'receipt.json'), ('settings', 'receipt.json'), ('app-smoke', 'receipt.json'), ('pipeline', 'pipeline.json')]:
    receipt = read(folder + '/' + name)
    assert receipt['result'] == 'Passed' and receipt['errors'] == 0 and receipt['stderr_bytes'] == 0
    assert receipt['visible_profile'] == 'none'
    for key in ['native_actions', 'native_hotkey_registrations', 'protected_folder_probes', 'native_login_changes', 'native_status_items', 'symbolichotkeys_writes']:
        if key in receipt: assert receipt[key] == 0, (folder, key)
    if folder != 'pipeline': assert receipt['cleanup'] == 'Owned process exited; test-created APPARATE_HOME removed'
assert read('pipeline/pipeline.json')['matched_hashes'] == 360
assert read('pipeline/cleanup.json')['owned_home_removed'] and read('pipeline/cleanup.json')['owned_process_exited']
refusals = read('driver-refusals.json')
assert refusals['decoy_never_launched'] and refusals['owned_home_removed'] and len(refusals['cases']) == 6
assert all(case['exit'] == 2 and case['result'] == 'Passed' for case in refusals['cases'])
upgrade, seed, check = read('upgrade/comparison.json'), read('upgrade/seed.json'), read('upgrade/check.json')
assert upgrade['result'] == 'Passed' and upgrade['all_processes_exited'] and upgrade['owned_home_removed']
assert all(seed[key] == check[key] for key in upgrade['matching_fields'])
assert check['data_directory_override'] and check['loaded_from_disk'] and check['completed_scans'] == 0 and not check['launched_app']
assert digest(root / '.build/production/release/ApparateUpgradeCheck') == upgrade['candidate_sha256']
assert digest(root / 'Tests/UpgradeCheck/UpgradeCheck.swift') == upgrade['harness_sha256']
retention = read('retention.json')
originals = Path(retention['original_final_images_archive'])
prior = json.loads((base.parent / '2026-11-20T121149Z-indexing-indicator/retention.json').read_text())
old_scenarios = {item['original']['file']: item['original']['sha256'] for item in prior['retained']}
assert len(retention['retained']) == 239 and retention['reused_prior_images'] == 238
for item in retention['retained']:
    assert digest(base / item['file']) == item['sha256'], item['file']
    original = item['original']
    assert digest(originals / original['file']) == original['sha256']
    if item.get('reused_prior'):
        assert old_scenarios[original['file']] == original['sha256']
for item in retention['superseded_images']:
    assert digest(originals / item['file']) == item['sha256']
assert len(retention['superseded_images']) == 239
demo = root / 'docs/assets/apparate-demo.png'
assert digest(demo) == digest(base / 'panel/apparate-demo.png')
assert struct.unpack('>II', demo.read_bytes()[16:24]) == (1280, 388)
assert struct.unpack('>II', (root / 'docs/assets/icon.png').read_bytes()[16:24]) == (1024, 1024)
assert read('panel/receipt.json')['release_demo'] == {'appearance':'dark', 'fixture_only':True, 'layout':'inline',
    'names':['Desk Notes','Desktop & Dock','Desktop','desktop-plan.md'], 'observation_marker':False, 'query':'desk'}
historical = root / 'build/review/2026-11-20-indexing-indicator/Apparate.app/Contents/MacOS/Apparate'
assert digest(historical) == 'ed436bbe06a3f516ef09c3e0a79d17fc5bda08f5457eae8a5c5145d1005ba5f1'
# Detailed privacy evidence is retained locally and is not a public artifact dependency.
result = {'result':'Passed', 'inputs_verified':len(manifest), 'core_unchanged_from_base':True,
    'production_archive_sha256':artifact['zip_sha256'], 'production_and_testing_signatures':True,
    'current_testing_comparator':'signed review bundle executable', 'core_suites':[134,134,134],
    'profiles':['panel','settings','app-smoke','pipeline'], 'pipeline_hashes':360, 'driver_refusals':6,
    'upgrade_fields_equal':True, 'upgrade_app_launched':False,
    'retained_render_scenarios':239, 'raw_matches_with_prior':238, 'superseded_raw_images_verified':239,
    'app_smoke_image_sha256':digest(base / 'app-smoke/panel.png'),
    'demo_sha256':digest(demo), 'historical_review_preserved':True,
    'app_launched_by_this_check':False}
(base / 'bundle-checks.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
