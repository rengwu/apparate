from pathlib import Path
import hashlib, json, plistlib, subprocess

base = Path(__file__).resolve().parent
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
manifest = json.loads((base / 'source-manifest.json').read_text())
for path, expected in manifest.items():
    assert digest(Path(path)) == expected, path
prior = json.loads((base.parent / '2026-11-20T115638Z-tight-paths/source-manifest.json').read_text())
result = {'source_inputs_verified': len(manifest),
          'changed_shared_inputs': [p for p in manifest if p in prior and manifest[p] != prior[p]],
          'new_inputs': [p for p in manifest if p not in prior], 'bundles': [], 'profiles': {}}
for name in ['build/review/2026-11-20-indexing-indicator/Apparate.app', 'build/Apparate.app']:
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
assert digest(Path('build/review/2026-11-20-skip-hidden/Apparate.app/Contents/MacOS/Apparate')) == '77fa1c2827972b67bf9d130cc1e60cf0e67fba29cdba1fa3eb33465a4ca94891'
assert digest(Path('build/review/2026-11-20-tight-paths/Apparate.app/Contents/MacOS/Apparate')) == 'f75e72e9045cdd1cdee92e88de164966afe3f26af2cf6994f184fb8fd88d5c1e'
result['section_12_bundle_preserved'] = True
result['section_13_bundle_preserved'] = True
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
for name in ['debug-settings', 'settings']:
    progress = json.loads((base / name / 'receipt.json').read_text())['indexing_indicator']
    assert progress['idle_frames'] == progress['all_indexing_frames']
    assert progress['mixed_idle_frames'] == progress['mixed_indexing_frames']
    assert progress['waiting_frames_unchanged'] and progress['native_switch_transitions'] == 4
    assert progress['same_folder_controls'] and progress['spinner_ax_label'] == 'Indexing'
result['indexing_frames_and_switch_transitions_verified'] = True
for item in retention['superseded_debug_images']:
    assert digest(Path(retention['original_final_images_archive']) / item['file']) == item['sha256']
result['superseded_debug_image_hashes_verified'] = len(retention['superseded_debug_images'])
result['memory_profile'] = 'Not repeated for section 14; section 11 comparison remains recorded separately with its budget failures.'
(base / 'bundle-checks.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
