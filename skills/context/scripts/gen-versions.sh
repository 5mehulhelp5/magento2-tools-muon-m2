#!/usr/bin/env bash
# gen-versions.sh — regenerate the Current Versions table in
# references/skill-versioning.md from each skill's SKILL.md frontmatter `version:`
# field. The frontmatter is the single source of truth; the table exists so tooling
# (and test-version-registry-consistency.sh) has one parseable registry view.
#
# Usage:  bash skills/context/scripts/gen-versions.sh          # rewrite in place
#         bash skills/context/scripts/gen-versions.sh --check  # exit 1 on drift
#
# The table is replaced between the BEGIN/END GENERATED markers; everything else in
# the file is left untouched.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
DOC="skills/context/references/skill-versioning.md"
MODE="${1:-write}"

python3 - "$DOC" "$MODE" <<'PY'
import os
import re
import sys

doc, mode = sys.argv[1], sys.argv[2]

rows = []
for skill in sorted(os.listdir('skills')):
    path = os.path.join('skills', skill, 'SKILL.md')
    if not os.path.isfile(path):
        continue
    text = open(path, encoding='utf-8').read()
    fm = re.match(r'^---\n(.*?)\n---\n', text, re.S)
    if not fm:
        sys.exit(f"FAIL: {path} has no frontmatter")
    m = re.search(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$', fm.group(1), re.M)
    if not m:
        sys.exit(f"FAIL: {path} frontmatter has no version: field")
    rows.append((skill, m.group(1)))

width = max(len(s) for s, _ in rows)
lines = [f"| {'Skill'.ljust(width)} | Version |",
         f"|{'-' * (width + 2)}|---------|"]
for skill, ver in rows:
    lines.append(f"| {skill.ljust(width)} | {ver.ljust(7)} |")
table = '\n'.join(lines)

BEGIN = '<!-- BEGIN GENERATED: versions (gen-versions.sh) -->'
END = '<!-- END GENERATED: versions -->'
text = open(doc, encoding='utf-8').read()
if BEGIN not in text or END not in text:
    sys.exit(f"FAIL: {doc} is missing the GENERATED markers")
new = re.sub(re.escape(BEGIN) + r'.*?' + re.escape(END),
             BEGIN + '\n' + table + '\n' + END, text, flags=re.S)

if mode == '--check':
    if new != text:
        sys.exit(f"FAIL: {doc} version table is stale — run gen-versions.sh")
    print("version table up to date")
else:
    open(doc, 'w', encoding='utf-8').write(new)
    print(f"wrote {len(rows)} version rows to {doc}")
PY
