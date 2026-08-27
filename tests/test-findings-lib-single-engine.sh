#!/usr/bin/env bash
# test-findings-lib-single-engine.sh — the audit skills share ONE findings engine.
# Every build-findings.sh must be a thin wrapper sourcing context's
# findings-lib.sh; none may re-implement the engine (run_scanner, scanner_errors
# assembly, findings merge) locally. Guards against the pre-2.0 state of six
# divergent copies.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LIB=skills/context/scripts/findings-lib.sh
FAIL=0

[ -f "$LIB" ] || { echo "FAIL: $LIB missing"; exit 1; }

# The library defines the engine exactly once.
for fn in findings_init findings_scan findings_register findings_emit; do
    grep -q "^${fn}()" "$LIB" || { echo "FAIL: $LIB does not define ${fn}()"; FAIL=1; }
done

WRAPPERS=$(ls skills/*/scripts/build-findings.sh)
[ -n "$WRAPPERS" ] || { echo "FAIL: no build-findings.sh wrappers found"; exit 1; }

for w in $WRAPPERS; do
    # Must source the shared library…
    grep -q 'context/scripts/findings-lib.sh' "$w" \
        || { echo "FAIL: $w does not source findings-lib.sh"; FAIL=1; }
    # …and must not re-implement engine internals locally.
    if grep -qE '^\s*run_scanner\(\)|scanner returned non-zero exit' "$w"; then
        echo "FAIL: $w re-implements the scanner engine locally"; FAIL=1
    fi
    if grep -q 'SKILL_VERSIONS_JSON=' "$w"; then
        echo "FAIL: $w hand-builds SKILL_VERSIONS_JSON (findings_emit owns that)"; FAIL=1
    fi
    # Thin means thin: the engine lives in the lib, wrappers stay under 120 lines
    # (the largest legitimate wrapper, static-analysis, is ~85 incl. its env docs).
    lines=$(wc -l < "$w")
    if [ "$lines" -gt 120 ]; then
        echo "FAIL: $w is ${lines} lines — no longer a thin wrapper"; FAIL=1
    fi
done

exit "$FAIL"
