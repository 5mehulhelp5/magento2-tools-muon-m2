#!/usr/bin/env bash
# test-version-table-generated.sh — skill versions live in SKILL.md frontmatter; the
# Current Versions table in skill-versioning.md is generated from them and must be
# fresh (byte-identical to the generator's output).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

FAIL=0

# Every skill declares a semver version in frontmatter.
for f in skills/*/SKILL.md; do
    if ! awk '/^---$/{c++; next} c==1 && /^version: [0-9]+\.[0-9]+\.[0-9]+$/{found=1} END{exit !found}' "$f"; then
        echo "FAIL: $f frontmatter lacks a semver version: field"; FAIL=1
    fi
done

# The generated table is fresh.
bash skills/context/scripts/gen-versions.sh --check >/dev/null \
    || { echo "FAIL: skill-versioning.md version table is stale — run gen-versions.sh"; FAIL=1; }

# The registry doc no longer carries a hand-maintained changelog (CHANGELOG.md is the
# durable record).
if grep -q '^## Changelog' skills/context/references/skill-versioning.md; then
    echo "FAIL: skill-versioning.md re-grew a hand-maintained changelog section"; FAIL=1
fi

exit "$FAIL"
