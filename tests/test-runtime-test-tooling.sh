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

POLICY="skills/context/references/runtime-test-tooling.md"
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
    grep -qF 'context/references/runtime-test-tooling.md' "$doc" \
        || fail "$label ($doc) has no pointer to the shared policy"
done <<'EOF'
skills/deploy/references/smoke-tests.md|deploy
skills/fix/references/reproduction-patterns.md|bug-fix
skills/a11y-audit/references/runtime-pa11y.md|accessibility-audit
EOF

# --- 3. feature-implement delegates and no longer skips the browser suites -----
FI_RUNNER="skills/feature/references/smoke-runner.md"
FI_GUIDE="skills/feature/references/smoke-test-guide.md"

for doc in "$FI_RUNNER" "$FI_GUIDE"; do
    [ -f "$doc" ] || { fail "feature-implement: $doc not found"; continue; }
    grep -qF 'context/references/runtime-test-tooling.md' "$doc" \
        || fail "feature-implement ($doc) has no pointer to the shared policy"
done

# REGRESSION GUARD: the old behaviour was "Skip S3-S7; record explicit limitation".
# Missing browser must now degrade to the curl tier, not vanish. Negated mentions
# ("does not skip S3-S7") are the CORRECT wording, so exclude them — otherwise the
# guard fires on the very sentence that documents the fix.
if grep -iE 'skip S3[-–]S7' "$FI_RUNNER" | grep -qivE "\bnot\b|\bnever\b"; then
    fail "$FI_RUNNER still instructs skipping S3-S7 instead of degrading to the curl tier"
fi

grep -qF 'curl tier' "$FI_RUNNER" \
    || fail "$FI_RUNNER does not describe the degraded curl tier"
grep -qF 'browser_policy' "$FI_RUNNER" \
    || fail "$FI_RUNNER does not resolve browser_policy"
grep -qF 'browser_policy' "$FI_GUIDE" \
    || fail "$FI_GUIDE does not account for browser_policy in its pass criteria"

# --- 4. The probe and the driver enumerate the SAME backends -------------------
# A bare google-chrome/chromium binary is not a backend: smoke-browser.mjs deleted its
# raw-CDP rung for fake-passing. If the context probe ever reports one again, browser_policy
# resolves to `auto`, the mandatory coverage finding is suppressed, and the curl tier runs
# while the report claims full coverage — the exact fake-pass this policy exists to block.
RESOLVER="skills/context/scripts/resolve-context.sh"
DRIVER="skills/feature/scripts/smoke-browser.mjs"

if [ -f "$RESOLVER" ]; then
    # Look only inside the probe function, so unrelated prose elsewhere cannot trip this.
    probe_body="$(sed -n '/^probe_headless_browser()/,/^}/p' "$RESOLVER")"
    if [ -z "$probe_body" ]; then
        fail "$RESOLVER has no probe_headless_browser function"
    elif printf '%s' "$probe_body" | grep -qE "printf '\"(google-chrome|chromium|chromium-browser)\""; then
        fail "$RESOLVER probe reports a bare Chrome/Chromium binary as a headless browser backend"
    fi
else
    fail "$RESOLVER not found"
fi

if [ -f "$DRIVER" ]; then
    # Strip `//` comment lines first: the file legitimately *discusses* the removed cdp
    # backend, and matching that prose would fire on the very note explaining the fix.
    if grep -vE '^\s*(//|\*|/\*)' "$DRIVER" | grep -qE 'return\s*\{\s*kind:\s*"cdp"'; then
        fail "$DRIVER reintroduced the raw-CDP backend that fake-passed smoke suites"
    fi
else
    fail "$DRIVER not found"
fi

exit "$FAIL"
