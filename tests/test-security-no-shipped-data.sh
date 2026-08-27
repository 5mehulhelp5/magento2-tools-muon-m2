#!/usr/bin/env bash
# test-security-no-shipped-data.sh — 2.0 contract: no advisory data ships with the
# security skill, the deleted CVE pipeline stays deleted, and an offline security
# build records the advisory degradation in scanner_errors instead of passing silently.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

FAIL=0
SEC=skills/security

# 1. No shipped advisory data or CVE pipeline.
for gone in references/magento-cve-data.yaml references/cve-extract.yaml \
            references/magento-cve-database.md scripts/cve-scan.sh \
            scripts/refresh-cve-data.py scripts/cve_parser.py scripts/cve_transforms.py \
            scripts/cve_data_lint.py scripts/inject-cve-status.sh; do
    [ ! -e "$SEC/$gone" ] || { echo "FAIL: $SEC/$gone should be deleted"; FAIL=1; }
done
# No YAML data files at all in the skill (advisories are resolved live).
if ls "$SEC"/references/*.yaml >/dev/null 2>&1; then
    echo "FAIL: $SEC/references ships YAML data again"; FAIL=1
fi

# 2. SKILL.md references no deleted mechanism.
for token in magento-cve-data cve-scan.sh inject-cve-status magento_core_cve_status; do
    if grep -q "$token" "$SEC/SKILL.md"; then
        echo "FAIL: SKILL.md still references $token"; FAIL=1
    fi
done

# 3. End-to-end offline run: advisory-scan degradation lands in scanner_errors.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src/app/code"
(cd "$WORK" && \
    TARGET_MODULE="Acme_Test" TARGET_PATH="src/app/code/Acme/Test" SCOPE="module" \
    SCAN_ROOT="src/app/code" COMPOSER_LOCK="$WORK/absent/composer.lock" \
    OUTPUT_DIR="$WORK/out" \
    bash "$OLDPWD/$SEC/scripts/build-findings.sh" >/dev/null 2>"$WORK/err")
JSON="$(ls "$WORK"/out/*.json 2>/dev/null | head -1)"
if [ -z "$JSON" ]; then
    echo "FAIL: offline security build produced no JSON"; cat "$WORK/err"; exit 1
fi
python3 - "$JSON" <<'PY' || FAIL=1
import json, sys
d = json.load(open(sys.argv[1]))
errs = {e['scanner']: e['stderr'] for e in d.get('scanner_errors', [])}
assert 'advisory-scan' in errs, f"advisory-scan degradation missing from scanner_errors: {list(errs)}"
assert 'NOT checked' in errs['advisory-scan'], errs['advisory-scan']
PY
[ "$FAIL" = 1 ] && echo "FAIL: scanner_errors assertions failed"

exit "$FAIL"
