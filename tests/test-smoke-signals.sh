#!/usr/bin/env bash
# The Phase 6B smoke gate must not report PASS when Magento recorded a failure somewhere other
# than var/log/exception.log. Three signal sources, verified against Magento 2.4.8 source:
#
#   1. var/report/**  — Webapi\ErrorProcessor::apiShutdownFunction() writes var/report/api/{id}
#      on a PHP fatal with NO logger call at all (framework/Webapi/ErrorProcessor.php:298-326).
#      pub/errors/processor.php nests reports under var/report/xx/yy/{sha256} when
#      MAGE_ERROR_REPORT_DIR_NESTING_LEVEL is set, so detection must recurse.
#   2. var/log/system.log and module channels — Logger\Handler\System::write() routes a record to
#      exception.log ONLY when $record['context']['exception'] is set. A string-level critical
#      (e.g. ObjectManager\Factory\AbstractFactory:127 "Type Error occurred when creating
#      object: …") lands in system.log and is invisible to an exception.log-only gate.
#   3. Log files that did not exist when the baseline was taken (a module channel opens on its
#      first write) must be scanned from byte 0, not skipped.
#
# Level gating is part of the contract: cron.log routinely carries 6-figure INFO volume, so
# "any new byte fails" is unusable. Only ERROR+ gates, and only when attributable to the
# feature's namespace (unattributed CRITICAL+ gates at High).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not on PATH"
    exit 77
fi

BASELINE_SH="$PWD/skills/magento2-feature-implement/scripts/smoke-baseline.sh"
DIFF_SH="$PWD/skills/magento2-feature-implement/scripts/smoke-tail-since.sh"
[ -x "$BASELINE_SH" ] || { echo "FAIL: $BASELINE_SH not executable"; exit 1; }
[ -x "$DIFF_SH" ] || { echo "FAIL: $DIFF_SH not executable"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }

LOGD="$WORK/src/var/log"
REPD="$WORK/src/var/report"
mkdir -p "$LOGD" "$REPD/ab/cd" "$REPD/api"
mkdir -p "$WORK/src/app/etc"
echo "<?php return ['backend' => ['frontName' => 'admin']];" > "$WORK/src/app/etc/env.php"

# Pre-existing content. Magento's default Monolog line format:
#   [ts] channel.LEVEL: message context extra
printf '[2026-07-01T10:00:00.000000+00:00] main.CRITICAL: pre-existing boom {"report_id":"old"} []\n' > "$LOGD/exception.log"
printf '[2026-07-01T10:00:00.000000+00:00] main.INFO: pre-existing info [] []\n' > "$LOGD/system.log"
printf '[2026-07-01T10:00:00.000000+00:00] main.INFO: Cron Job foo is run [] []\n' > "$LOGD/cron.log"
printf '[2026-07-01T10:00:00.000000+00:00] main.DEBUG: cache load [] []\n' > "$LOGD/debug.log"
printf '{"0":"pre-existing report","1":"#0 trace","url":"\\/x","script_name":"\\/index.php","report_id":"aabb"}\n' \
    > "$REPD/ab/cd/aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
printf '"Fatal Error: pre-existing api fatal"\n' > "$REPD/api/1111111111"

# Baseline timestamps must sort strictly before anything written during the "run".
find "$WORK/src/var" -exec touch -d '2026-07-01T10:00:00' {} +

cd "$WORK"
BASE="$WORK/smoke/baseline.txt"
"$BASELINE_SH" "$BASE" "$WORK/src" >/dev/null 2>"$WORK/base.err" \
    || fail "baseline script exited non-zero: $(cat "$WORK/base.err")"

# --- 1. baseline shape -------------------------------------------------------------------
# Legacy keys stay, so an in-flight run started on the old scripts still parses.
for k in file size_bytes sha256_of_last_4096 captured_at; do
    grep -q "^${k}=" "$BASE" || fail "baseline lost legacy key '${k}='"
done
grep -q '^file=.*/var/log/exception\.log$' "$BASE" || fail "legacy file= no longer points at exception.log"
# New manifest sections.
grep -q '^\[logs\]' "$BASE" || fail "baseline has no [logs] section"
grep -q '^\[reports\]' "$BASE" || fail "baseline has no [reports] section"
for f in exception.log system.log cron.log debug.log; do
    grep -q "^log=.*/${f}|" "$BASE" || fail "baseline [logs] missing ${f}"
done
[ "$(grep -c '^report=' "$BASE")" = "2" ] \
    || fail "baseline [reports] should list 2 pre-existing report files, got $(grep -c '^report=' "$BASE")"

run_diff() {
    # run_diff <out-dir> [extra args...] -> echoes exit code, leaves signals.json in <out-dir>
    local out="$1"; shift
    mkdir -p "$out"
    local rc=0
    "$DIFF_SH" "$BASE" "$out/exception-diff.log" --json="$out/signals.json" "$@" \
        >"$out/stdout.txt" 2>"$out/stderr.txt" || rc=$?
    echo "$rc"
}

jq_py() {
    # jq_py <signals.json> <python expression over `d`>
    python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print($2)
" "$1" "$2"
}

# --- 2. quiet run: nothing changed → no signals ------------------------------------------
rc="$(run_diff "$WORK/o2")"
[ "$rc" = "0" ] || fail "case 2 (no change): expected exit 0, got $rc"
[ -f "$WORK/o2/signals.json" ] || fail "case 2: no signals.json written"
if [ -f "$WORK/o2/signals.json" ]; then
    got="$(jq_py "$WORK/o2/signals.json" "d['counts']['gating']")"
    [ "$got" = "0" ] || fail "case 2: expected 0 gating signals, got $got"
fi

# --- 3. new report file, flat layout → gating ---------------------------------------------
printf '{"0":"Report only, nothing logged","1":"#0 trace","url":"\\/checkout","script_name":"\\/index.php","report_id":"newflat"}\n' \
    > "$REPD/1122334455667788990011223344556677889900112233445566778899001122"
rc="$(run_diff "$WORK/o3")"
[ "$rc" = "1" ] || fail "case 3 (new report file): expected exit 1 (gating), got $rc"
if [ -f "$WORK/o3/signals.json" ]; then
    n="$(jq_py "$WORK/o3/signals.json" "sum(1 for f in d['findings'] if f['category']=='report_file' and f['gating'])")"
    [ "$n" = "1" ] || fail "case 3: expected 1 gating report_file finding, got $n"
fi

# --- 4. report file rewritten in place (same content-hash name, new mtime) ----------------
# Magento names the report after a hash of its content, so a recurring exception overwrites the
# same path. A path-set diff alone would miss it; mtime must be compared too.
printf '{"0":"pre-existing report","1":"#0 trace v2","url":"\\/x","script_name":"\\/index.php","report_id":"aabb"}\n' \
    > "$REPD/ab/cd/aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
rc="$(run_diff "$WORK/o4")"
[ "$rc" = "1" ] || fail "case 4 (report rewritten in place): expected exit 1, got $rc"
if [ -f "$WORK/o4/signals.json" ]; then
    n="$(jq_py "$WORK/o4/signals.json" "d['sources']['reports']['refreshed']")"
    [ "$n" = "1" ] || fail "case 4: expected refreshed=1, got $n"
fi
rm -f "$REPD/1122334455667788990011223344556677889900112233445566778899001122"
touch -d '2026-07-01T10:00:00' "$REPD/ab/cd/aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"

# --- 5. attributed CRITICAL in system.log → gating, Critical -----------------------------
# The live case: AbstractFactory logs a DI TypeError as a *string* critical, so it never
# reaches exception.log.
printf '[2026-07-29T23:20:27.147314+00:00] main.CRITICAL: Type Error occurred when creating object: Acme\\Widget\\Plugin\\Enricher, Too few arguments [] []\n' \
    >> "$LOGD/system.log"
rc="$(run_diff "$WORK/o5" --namespace=Acme_Widget)"
[ "$rc" = "1" ] || fail "case 5 (attributed CRITICAL in system.log): expected exit 1, got $rc"
if [ -f "$WORK/o5/signals.json" ]; then
    n="$(jq_py "$WORK/o5/signals.json" "sum(1 for f in d['findings'] if f['category']=='log_error' and f['gating'] and f['severity']=='Critical')")"
    [ "$n" = "1" ] || fail "case 5: expected 1 gating Critical log_error, got $n"
    # exception.log did not move — the legacy diff must be empty, proving the new signal is
    # what caught it.
    [ -s "$WORK/o5/exception-diff.log" ] && fail "case 5: exception-diff.log should be empty"
fi
: > "$LOGD/system.log"
printf '[2026-07-01T10:00:00.000000+00:00] main.INFO: pre-existing info [] []\n' > "$LOGD/system.log"
touch -d '2026-07-01T10:00:00' "$LOGD/system.log"

# --- 6. INFO churn in cron.log → NOT gating ----------------------------------------------
for i in $(seq 1 500); do
    printf '[2026-07-29T23:30:%02d.000000+00:00] main.INFO: Cron Job job_%s is run [] []\n' $((i % 60)) "$i"
done >> "$LOGD/cron.log"
rc="$(run_diff "$WORK/o6")"
[ "$rc" = "0" ] || fail "case 6 (500 INFO lines in cron.log): expected exit 0, got $rc"

# --- 7. log file created during the run → scanned from byte 0 -----------------------------
printf '[2026-07-29T23:40:00.000000+00:00] acme.ERROR: Acme_Widget failed to sync [] []\n' \
    > "$LOGD/acme_widget.log"
rc="$(run_diff "$WORK/o7" --namespace=Acme_Widget)"
[ "$rc" = "1" ] || fail "case 7 (new log file mid-run): expected exit 1, got $rc"
if [ -f "$WORK/o7/signals.json" ]; then
    n="$(jq_py "$WORK/o7/signals.json" "sum(1 for l in d['sources']['logs'] if l['created_during_run'])")"
    [ "$n" = "1" ] || fail "case 7: expected 1 created_during_run log, got $n"
fi
rm -f "$LOGD/acme_widget.log"

# --- 8. unattributed plain ERROR → recorded, not gating (exit 4) --------------------------
printf '[2026-07-29T23:45:00.000000+00:00] main.ERROR: Could not create an acl object: Resource id already exists [] []\n' \
    >> "$LOGD/system.log"
rc="$(run_diff "$WORK/o8" --namespace=Acme_Widget)"
[ "$rc" = "4" ] || fail "case 8 (unattributed ERROR): expected exit 4 (recorded, non-gating), got $rc"
if [ -f "$WORK/o8/signals.json" ]; then
    g="$(jq_py "$WORK/o8/signals.json" "d['counts']['gating']")"
    r="$(jq_py "$WORK/o8/signals.json" "d['counts']['recorded']")"
    [ "$g" = "0" ] || fail "case 8: expected 0 gating, got $g"
    [ "$r" -ge 1 ] || fail "case 8: expected >=1 recorded, got $r"
fi

# --- 9. exception.log append: legacy contract unchanged -----------------------------------
printf '[2026-07-29T23:50:00.000000+00:00] main.CRITICAL: Acme\\Widget\\Model\\Sync boom {"exception":"[object] (TypeError…)"} []\n' \
    >> "$LOGD/exception.log"
rc="$(run_diff "$WORK/o9" --namespace=Acme_Widget)"
[ "$rc" = "1" ] || fail "case 9 (exception.log append): expected exit 1, got $rc"
grep -q 'Acme.Widget.Model.Sync boom' "$WORK/o9/exception-diff.log" \
    || fail "case 9: exception-diff.log must contain exactly the appended bytes"
grep -q 'pre-existing boom' "$WORK/o9/exception-diff.log" \
    && fail "case 9: exception-diff.log leaked pre-baseline bytes"

# --- 10. new api report (fatal, never logged) → gating ------------------------------------
printf '"Fatal Error: Allowed memory size exhausted in Acme/Widget/Model/Sync.php on line 42"\n' \
    > "$REPD/api/2222222222"
rc="$(run_diff "$WORK/o10" --namespace=Acme_Widget)"
[ "$rc" = "1" ] || fail "case 10 (new api report): expected exit 1, got $rc"
if [ -f "$WORK/o10/signals.json" ]; then
    n="$(jq_py "$WORK/o10/signals.json" "sum(1 for f in d['findings'] if f['category']=='report_file')")"
    [ "$n" -ge 1 ] || fail "case 10: api report not reported as a finding"
fi

# --- 11. rotation of exception.log still detected -----------------------------------------
mv "$LOGD/exception.log" "$LOGD/exception.log.1"
printf '[2026-07-29T23:55:00.000000+00:00] main.CRITICAL: post-rotation boom [] []\n' > "$LOGD/exception.log"
rc="$(run_diff "$WORK/o11")"
[ "$rc" = "1" ] || fail "case 11 (rotation): expected exit 1, got $rc"
grep -q 'ROTATION DETECTED' "$WORK/o11/exception-diff.log" \
    || fail "case 11: rotation marker missing from exception-diff.log"

# --- 12. malformed baseline still exits 2 --------------------------------------------------
echo "garbage" > "$WORK/bad-baseline.txt"
rc=0
"$DIFF_SH" "$WORK/bad-baseline.txt" "$WORK/o12/exception-diff.log" >/dev/null 2>&1 || rc=$?
[ "$rc" = "2" ] || fail "case 12 (malformed baseline): expected exit 2, got $rc"

# --- 13. cron.log ERROR: gates only when a cron/queue surface is declared -------------------
# Re-baseline first: cases 3-11 deliberately left gating signals in the fixture, and this case
# asserts an exit code that only means anything from a quiet starting state.
"$BASELINE_SH" "$BASE" "$WORK/src" >/dev/null 2>&1 || fail "case 13: re-baseline failed"
rc="$(run_diff "$WORK/o13pre")"
[ "$rc" = "0" ] || fail "case 13 precondition: re-baselined state should be quiet, got $rc"

printf '[2026-07-30T00:10:00.000000+00:00] main.ERROR: Cron Job acme_sync has an error: boom [] []\n' \
    >> "$LOGD/cron.log"
rc="$(run_diff "$WORK/o13a")"
[ "$rc" = "4" ] || fail "case 13a (cron ERROR, no surface declared): expected exit 4, got $rc"
rc="$(run_diff "$WORK/o13b" --surfaces=cron)"
[ "$rc" = "1" ] || fail "case 13b (cron ERROR, cron surface declared): expected exit 1, got $rc"

# --- 14. a pre-manifest baseline must exit 5 (degraded), never 0 ----------------------------
# An older smoke-baseline.sh wrote only the four legacy keys. Reading that as a clean run would
# reinstate exactly the false PASS this whole change exists to remove.
grep -v -e '^\[logs\]' -e '^\[reports\]' -e '^log=' -e '^report=' "$BASE" > "$WORK/v1-baseline.txt"
rc=0
"$DIFF_SH" "$WORK/v1-baseline.txt" "$WORK/o14/exception-diff.log" >/dev/null 2>"$WORK/o14.err" || rc=$?
[ "$rc" = "5" ] || fail "case 14 (pre-manifest baseline): expected exit 5 (degraded), got $rc"
grep -q "NOT checked" "$WORK/o14.err" \
    || fail "case 14: degraded exit must say on stderr which sources went unchecked"

exit "$FAIL"
