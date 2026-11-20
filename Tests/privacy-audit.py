#!/usr/bin/env python3
"""Read-only advisory inventory of repository text/history and image blobs."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--images', type=Path, required=True, help='Owned scratch directory for unique image blobs')
parser.add_argument('--personal-name', action='append', default=[], help='Known private name to locate without hardcoding it in the scanner')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
args.images.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
account = Path.home().name
patterns = {
    'home_path': re.compile(r'(?:/Users/[A-Za-z0-9._-]+|/private/tmp/claude-[^/\s"\'<>]+)'),
    'account_identifier': re.compile(re.escape(account), re.I),
    'email_address': re.compile(r'[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    'project_path': re.compile(r'(?:~/Projects|/Users/[^/\s"\'<>]+/Projects)/([^/\s"\'<>\\)]+)'),
    'application_path': re.compile(r'/Applications/([^/\n"\'<>\\]{1,100}\.app)'),
    'known_personal_folder': re.compile('|'.join(re.escape(name) for name in args.personal_name) if args.personal_name else r'(?!)', re.I),
}
blobs = {}
commits = subprocess.check_output(['git', 'rev-list', '--all'], cwd=root, text=True).splitlines()
for commit in commits:
    for entry in subprocess.check_output(['git', 'ls-tree', '-rz', commit], cwd=root).split(b'\0'):
        if not entry: continue
        meta, name = entry.split(b'\t', 1)
        mode, kind, oid = meta.decode().split()
        if kind != 'blob': continue
        item = blobs.setdefault(oid, {'paths': set(), 'commits': [], 'current': []})
        item['paths'].add(name.decode())
        if commit not in item['commits']: item['commits'].append(commit)
current = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).split(b'\0')
for raw in sorted(set(current)):
    if not raw: continue
    name = raw.decode(); path = root / name
    # The audit's own generated outputs are described in its coverage receipt.
    if not path.is_file() or args.output.resolve() in path.resolve().parents: continue
    data = path.read_bytes()
    oid = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    item = blobs.setdefault(oid, {'paths': set(), 'commits': [], 'current': [], 'data': data})
    item['paths'].add(name); item['current'].append(name)
findings, images, skipped, terms = [], [], [], defaultdict(Counter)
process = subprocess.Popen(['git', 'cat-file', '--batch'], cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
try:
    for oid, item in blobs.items():
        if 'data' in item: data = item.pop('data')
        else:
            process.stdin.write((oid + '\n').encode()); process.stdin.flush()
            header = process.stdout.readline().split(); size = int(header[2])
            data = process.stdout.read(size); assert process.stdout.read(1) == b'\n'
        descriptor = {'blob': oid, 'paths': sorted(item['paths']), 'commits': item['commits'], 'current_paths': item['current'], 'bytes': len(data)}
        suffix = next((Path(p).suffix.lower() for p in item['paths'] if Path(p).suffix.lower() in ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.icns']), None)
        if suffix:
            destination = args.images / (oid + suffix); destination.write_bytes(data)
            descriptor['scratch_image'] = str(destination)
            images.append(descriptor); continue
        if b'\0' in data:
            skipped.append(descriptor); continue
        content = data.decode('utf-8', errors='replace')
        matches = {}
        for category, pattern in patterns.items():
            lines = []
            for number, line in enumerate(content.splitlines(), 1):
                hits = list(pattern.finditer(line))
                if category == 'email_address': hits = [hit for hit in hits if not re.search(r'@[123]x\.(?:png|jpg)$', hit.group(), re.I)]
                if hits:
                    lines.append(number)
                    for hit in hits: terms[category][hit.group(1) if hit.lastindex else hit.group()] += 1
            if lines: matches[category] = {'line_numbers': lines, 'line_count': len(lines)}
        if matches: findings.append({**descriptor, 'matches': matches})
finally:
    process.stdin.close(); process.stdout.close(); process.wait()
# Diff and metadata are checked independently, including author identities.
history = subprocess.check_output(['git', 'log', '--all', '-p', '--format=commit %H%nAuthor: %an <%ae>%nCommitter: %cn <%ce>'], cwd=root, text=True, errors='replace')
history_counts = {name: len(pattern.findall(history)) for name, pattern in patterns.items()}
authors = subprocess.check_output(['git', 'log', '--all', '--format=%an <%ae>'], cwd=root, text=True).splitlines()
evidence = root / 'docs/wiki/evidence'
evidence_files = [(str(p.relative_to(root)), p.stat().st_size) for p in evidence.rglob('*') if p.is_file() and args.output.resolve() not in p.resolve().parents]
report = {'scope': 'Tracked and intended untracked files plus all reachable commit trees, git log -p, author/committer metadata. Audit outputs excluded to avoid self-recursion.',
          'commits': len(commits), 'unique_blobs': len(blobs), 'text_findings': findings, 'images': images, 'unread_binary_blobs': skipped,
          'history_diff_match_counts': history_counts, 'author_identities': dict(Counter(authors)),
          'terms': {key: dict(value.most_common()) for key, value in terms.items()},
          'evidence_bytes_before_audit': sum(n for _, n in evidence_files),
          'largest_evidence_files': sorted(evidence_files, key=lambda p: p[1], reverse=True)[:20],
          'historical_only_findings': sum(not f['current_paths'] for f in findings),
          'findings_not_redactions': True}
(args.output / 'privacy-inventory.json').write_text(json.dumps(report, indent=2) + '\n')
(args.images / 'manifest.json').write_text(json.dumps([{'id': x['blob'], 'file': x['scratch_image']} for x in images]) + '\n')
print(json.dumps({'commits': len(commits), 'unique_blobs': len(blobs), 'text_findings': len(findings), 'images': len(images), 'other_binary_blobs': len(skipped), 'evidence_bytes': report['evidence_bytes_before_audit']}, indent=2))
