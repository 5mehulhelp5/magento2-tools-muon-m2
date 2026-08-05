#!/usr/bin/env bash
# Runtime test tooling policy contract.
#
# Guards three things that are easy to regress by editing prose:
#   1. The shared policy exists and still states all five rules plus the full
#      six-row browser_policy precedence order.
#   2. Every skill that exercises a running Magento instance delegates to it
#      (one-line pointer, per the repo's "delegate, never copy" convention).
#   3. Phase 6B no longer skips the admin/storefront suites when no browser is
#      available — it degrades to the curl tier instead.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

POLICY="skills/magento2-context/references/runtime-test-tooling.md"
FAIL=0

fail() {
    echo "FAIL: $*"
    FAIL=1
}

# --- 1. The policy document ---------------------------------------------------
if [ ! -f "$POLICY" ]; then
    echo "FAIL: shared policy missing at $POLICY"
    exit 1
fi

for needle in \
    'Rule 1' 'Rule 2' 'Rule 3' 'Rule 4' 'Rule 5' \
    'curl-only' 'auto' \
    'MAGENTO2_SMOKE_NO_BROWSER' \
    'Smoke browser: off' \
    '--no-browser' \
    'degraded-coverage finding is mandatory'
do
    grep -qF -- "$needle" "$POLICY" || fail "$POLICY does not mention '$needle'"
done

# The precedence ladder must keep all six sources. Losing a row silently changes
# which signal wins, which is the whole point of the file.
for source in \
    'prompt' 'flag' 'CLAUDE.md' 'env' 'probe' 'otherwise'
do
    grep -qiF -- "$source" "$POLICY" || fail "$POLICY precedence table lost the '$source' row"
done

# --- 2. Delegating skills carry a pointer ------------------------------------
while IFS='|' read -r doc label; do
    [ -f "$doc" ] || { fail "$label: $doc not found"; continue; }
    grep -qF 'magento2-context/references/runtime-test-tooling.md' "$doc" \
        || fail "$label ($doc) has no pointer to the shared policy"
done <<'EOF'
skills/magento2-deploy/references/smoke-tests.md|deploy
skills/magento2-bug-fix/references/reproduction-patterns.md|bug-fix
skills/magento2-accessibility-audit/references/runtime-pa11y.md|accessibility-audit
EOF

exit "$FAIL"
