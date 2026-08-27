#!/usr/bin/env bash
# test-docs-root-threading.sh — every artifact-producing skill documents the
# --docs-root output-root override in its SKILL.md.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Task 3 covers the 9 script-backed emitters; Task 4 extends this array to the
# remaining 15 LLM-report skills.
SKILLS=(
    review security perf-audit
    lint marketplace a11y-audit
    breeze-compat upgrade deploy
    test-generate docs release i18n
    debug fix admin-form admin-listing
    cli-command eav-attribute extension-point
    indexer message-queue system-config data-migration
)

FAIL=0
for s in "${SKILLS[@]}"; do
    f="skills/${s}/SKILL.md"
    if [ ! -f "$f" ]; then echo "FAIL: $f missing"; FAIL=1; continue; fi
    if ! grep -q -- '--docs-root' "$f"; then
        echo "FAIL: ${s}/SKILL.md does not document --docs-root"; FAIL=1
    fi
done
exit "$FAIL"
