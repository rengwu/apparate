from pathlib import Path
import hashlib, json, plistlib, subprocess

base = Path(__file__).resolve().parent
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
manifest = json.loads((base / 'source-manifest.json').read_text())
for path, expected in manifest.items():
    assert digest(Path(path)) == expected, path
prior = json.loads((base.parent / '2026-11-20T111919Z-below-icons/source-manifest.json').read_text())
result = {'source_inputs_verified': len(manifest),
          'changed_shared_inputs': [p for p in manifest if p in prior and manifest[p] != prior[p]],
          'new_inputs': [p for p in manifest if p not in prior], 'bundles': [], 'profiles': {}}
for name in ['build/review/2026-11-20-skip-hidden/Apparate.app', 'build/Apparate.app']:
    bundle = Path(name)
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIconFile'] == 'AppIcon'
    assert digest(bundle / 'Contents/Resources/AppIcon.icns') == digest(Path('Resources/AppIcon.icns'))
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    result['bundles'].append({'bundle': name, 'identifier': info['CFBundleIdentifier'],
        'app_sha256': digest(bundle / 'Contents/MacOS/Apparate'), 'icon_sha256': digest(bundle / 'Contents/Resources/AppIcon.icns'),
        'CFBundleIconFile': info['CFBundleIconFile'], 'strict_deep_signature_verified': True})
assert result['bundles'][0]['app_sha256'] == json.loads((base / 'build-identity.json').read_text())['app_sha256']
assert digest(Path('build/review/2026-11-20-below-icons/Apparate.app/Contents/MacOS/Apparate')) == 'f47335321d554595ce3e9182d90cbc0586410f5f877d31a1f30d4aeff3c85c95'
retention = json.loads((base / 'retention.json').read_text())
for item in retention['retained']:
    assert digest(base / item['file']) == item['sha256'], item['file']
    assert digest(Path(retention['original_final_images_archive']) / item['original']['file']) == item['original']['sha256']
result.update(render_scenarios_verified=len(retention['retained']), reused_prior_images=retention['reused_prior_images'],
              local_images=len(list(base.rglob('*.jpg'))), section_11_bundle_preserved=True)
for name in ['debug-settings', 'settings', 'panel']:
    receipt = json.loads((base / name / 'receipt.json').read_text())
    assert receipt['result'] == 'Passed' and receipt['stderr_bytes'] == 0 and receipt['visible_profile'] == 'none'
    effects = sum(receipt.get(k, 0) for k in ['native_actions', 'native_hotkey_registrations', 'native_login_changes', 'native_status_items', 'protected_folder_probes'])
    assert effects == 0
    result['profiles'][name] = dict(result=receipt['result'], stderr_bytes=0, native_effects=effects, cleanup=receipt['cleanup'])
for name in ['pipeline-prior', 'pipeline-candidate']:
    receipt = json.loads((base / name / 'pipeline.json').read_text())
    cleanup = json.loads((base / name / 'cleanup.json').read_text())
    assert receipt['result'] == 'Passed' and receipt['matched_hashes'] == 360 and receipt['stderr_bytes'] == 0
    assert cleanup['owned_process_exited'] and cleanup['owned_home_removed']
comparison = json.loads((base / 'pipeline-comparison.json').read_text())
assert comparison['compared_rows'] == 360 and not comparison['mismatches']
result['pipeline_off_equal_digests'] = 360
result['memory_profile'] = 'Not repeated; section 11 installed-app read clarification remains pending'
(base / 'bundle-checks.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
