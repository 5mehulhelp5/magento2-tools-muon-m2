#!/usr/bin/env bash
# Each single-surface generator tells the user to refresh docs after it mutates a module.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SKILLS=(
    webapi graphql frontend
    admin-form admin-listing cli-command
    eav-attribute extension-point system-config
    message-queue indexer data-migration widget
)
FAIL=0
for s in "${SKILLS[@]}"; do
    f="skills/${s}/SKILL.md"
    grep -q 'Docs may now be stale' "$f" \
        || { echo "FAIL: ${s}/SKILL.md missing the 'Docs may now be stale' callout"; FAIL=1; }
    grep -q 'docs --module=' "$f" \
        || { echo "FAIL: ${s}/SKILL.md missing 'docs --module=' command"; FAIL=1; }
done
exit "$FAIL"
