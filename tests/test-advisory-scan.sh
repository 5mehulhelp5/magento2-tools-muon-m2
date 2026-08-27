#!/usr/bin/env bash
# test-advisory-scan.sh — the live dependency-advisory scanner (composer audit +
# vendor/bin/patch-status), which replaced the shipped CVE registry in 2.0.
# Covers: offline degradation, composer-audit parsing (incl. the null-`cve` GHSA
# case), patch-status verdict handling, opt-out, and broken-tool degradation.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

SCAN="$PWD/skills/security/scripts/advisory-scan.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0

# --- 1. No composer.lock: [] on stdout, "NOT checked" on stderr -------------------
out="$(cd "$WORK" && bash "$SCAN" missing/composer.lock 2>"$WORK/err1")"
[ "$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin))')" = "[]" ] \
    || { echo "FAIL: no-lockfile run should emit []"; FAIL=1; }
grep -q 'dependency advisories were NOT checked' "$WORK/err1" \
    || { echo "FAIL: no-lockfile run must say advisories were NOT checked"; FAIL=1; }

# --- 2. composer audit advisories are parsed (stubbed composer) -------------------
mkdir -p "$WORK/proj" "$WORK/bin"
echo '{}' > "$WORK/proj/composer.lock"
cat > "$WORK/bin/composer" <<'STUB'
#!/usr/bin/env bash
# Stub: emit one classic advisory and one GHSA-only advisory (cve key present but null),
# and exit 1 — composer audit exits non-zero exactly when advisories exist.
cat <<'JSON'
{"advisories": {"acme/lib": [
  {"title": "RCE in acme/lib", "severity": "critical", "cve": "CVE-2026-0001",
   "reportedAt": "2026-01-01", "sources": [{"name": "GitHub", "remoteId": "GHSA-aaaa"}]},
  {"title": "XSS in acme/lib", "severity": "bogus-severity", "cve": null,
   "reportedAt": 12345, "sources": [{"name": "GitHub", "remoteId": "GHSA-h95v"}]}
]}}
JSON
exit 1
STUB
chmod +x "$WORK/bin/composer"
(cd "$WORK/proj" && PATH="$WORK/bin:$PATH" bash "$SCAN" composer.lock 2>"$WORK/err2") > "$WORK/out2"
python3 - "$WORK/out2" <<'PY' || FAIL=1
import json, sys
f = json.load(open(sys.argv[1]))
assert len(f) == 2, f"expected 2 advisory findings, got {len(f)}"
assert f[0]['severity'] == 'critical' and f[0]['cve'] == 'CVE-2026-0001'
assert f[0]['category'] == 'cve' and f[0]['confidence'] == 'confirmed'
# Unknown severity normalises to medium; null cve falls through to the GHSA remoteId.
assert f[1]['severity'] == 'medium', f[1]['severity']
assert 'GHSA-h95v' in f[1]['recommendation'], f[1]['recommendation']
assert 'None' not in f[1]['recommendation'], "null cve leaked into recommendation"
PY
[ "$FAIL" = 1 ] && echo "FAIL: composer-audit parsing assertions"

# --- 3. Invalid composer JSON: [] + loud stderr -----------------------------------
cat > "$WORK/bin/composer" <<'STUB'
#!/usr/bin/env bash
echo 'this is not json'
exit 0
STUB
chmod +x "$WORK/bin/composer"
out="$(cd "$WORK/proj" && PATH="$WORK/bin:$PATH" bash "$SCAN" composer.lock 2>"$WORK/err3")"
[ "$(echo "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "0" ] \
    || { echo "FAIL: invalid composer JSON should yield 0 findings"; FAIL=1; }
grep -q 'NOT parsed' "$WORK/err3" \
    || { echo "FAIL: invalid composer JSON must be surfaced on stderr"; FAIL=1; }

# --- 4. patch-status VULNERABLE becomes a finding; PROTECTED does not -------------
rm -f "$WORK/bin/composer"   # composer absent from here on
mkdir -p "$WORK/proj/vendor/bin"
cat > "$WORK/proj/vendor/bin/patch-status" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerability_status": {
  "CVE-2026-1111": {"status": "VULNERABLE"},
  "CVE-2026-2222": {"status": "PROTECTED"},
  "CVE-2026-3333": {"status": "NOT_APPLICABLE"},
  "CVE-2026-4444": {"status": "UNKNOWN"}
}}
JSON
STUB
chmod +x "$WORK/proj/vendor/bin/patch-status"
(cd "$WORK/proj" && bash "$SCAN" composer.lock 2>"$WORK/err4") > "$WORK/out4"
python3 - "$WORK/out4" <<'PY' || { echo "FAIL: patch-status verdict assertions"; FAIL=1; }
import json, sys
f = json.load(open(sys.argv[1]))
assert len(f) == 1, f"only VULNERABLE should become a finding, got {len(f)}"
assert f[0]['cve'] == 'CVE-2026-1111' and f[0]['severity'] == 'high'
assert 'patch-status' in f[0]['tags']
PY

# --- 5. PATCH_STATUS=0 opts out (tool present but never run) ----------------------
out="$(cd "$WORK/proj" && PATCH_STATUS=0 bash "$SCAN" composer.lock 2>"$WORK/err5")"
[ "$(echo "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "0" ] \
    || { echo "FAIL: PATCH_STATUS=0 must not produce patch findings"; FAIL=1; }
grep -q 'patch-status' "$WORK/err5" \
    && { echo "FAIL: PATCH_STATUS=0 should not mention patch-status on stderr"; FAIL=1; }

# --- 6. Broken patch-status (garbage, exit 0): degrade loudly ---------------------
cat > "$WORK/proj/vendor/bin/patch-status" <<'STUB'
#!/usr/bin/env bash
echo "PHP Fatal error: something"
exit 0
STUB
out="$(cd "$WORK/proj" && bash "$SCAN" composer.lock 2>"$WORK/err6")"
grep -q 'no usable JSON' "$WORK/err6" \
    || { echo "FAIL: broken patch-status must degrade loudly"; FAIL=1; }

# --- 7. Absent patch-status: recorded, not silent ---------------------------------
rm -rf "$WORK/proj/vendor"
out="$(cd "$WORK/proj" && bash "$SCAN" composer.lock 2>"$WORK/err7")"
grep -q 'not installed' "$WORK/err7" \
    || { echo "FAIL: absent patch-status must be recorded on stderr"; FAIL=1; }

exit "$FAIL"
