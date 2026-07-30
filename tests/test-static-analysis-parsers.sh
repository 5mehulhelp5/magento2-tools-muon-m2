#!/usr/bin/env bash
# test-static-analysis-parsers.sh — run-analysis.sh must actually PARSE what each tool emits, and
# must surface a tool's stderr rather than swallowing it.
#
# Regression test for a false clean: all three tool passes failed independently and the document
# still reported `findings: []` with `scanner_errors: []`, which is indistinguishable from a pass.
#   * phpcs  — PHP_CodeSniffer prints "DEPRECATED: ..." to STDOUT ahead of the --report=json
#              payload, so json.load() failed and the parser fell back to [].
#   * phpmd  — the parser read a top-level "violations" key that PHPMD does not emit (the real
#              shape nests violations under "files"), so the loop ran zero times and the JSON
#              still parsed cleanly — no error raised anywhere.
#   * phpstan — on a crash it returns files: [] (a LIST), and .values() on that raised an
#              uncaught AttributeError; the crash text in "errors" was discarded.
# The three were invisible because run-analysis.sh wrote each tool's stderr to a temp file it
# never forwarded, and that stderr is the ONLY channel build-findings.sh turns into scanner_errors.
#
# Tools are stubbed, so this runs without phpcs/phpstan/phpmd installed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not on PATH"
    exit 77
fi

SCRIPT="skills/magento2-static-analysis/scripts/run-analysis.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; MOD="$WORK/module"; mkdir -p "$BIN" "$MOD/etc"

cat > "$MOD/etc/module.xml" <<'XML'
<?xml version="1.0"?>
<config><module name="Acme_Foo"/></config>
XML
printf '<?php\n' > "$MOD/registration.php"

# --- stub phpcs: deprecation preamble on STDOUT, then the real JSON report -------------------
cat > "$BIN/phpcs" <<'STUB'
#!/usr/bin/env bash
echo "DEPRECATED: Support for custom tokenizers will be removed in PHP_CodeSniffer 4.0."
echo "The Magento2.GraphQL.ValidFieldName sniff is listening for GRAPHQL."
cat <<'JSON'
{"totals":{"errors":1,"warnings":1,"fixable":0},"files":{"/m/A.php":{"errors":1,"warnings":1,"messages":[
{"message":"Real error here","source":"Magento2.Legacy.Sniff","severity":5,"fixable":false,"type":"ERROR","line":12,"column":1},
{"message":"Real warning here","source":"Magento2.Annotation.Sniff","severity":5,"fixable":false,"type":"WARNING","line":30,"column":1}]}}}
JSON
exit 1
STUB

# --- stub phpmd: violations nested under files (the real 2.x renderer shape) -----------------
cat > "$BIN/phpmd" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"version":"2.15.0","package":"phpmd","files":[{"file":"/m/A.php","violations":[
{"beginLine":43,"endLine":43,"rule":"LongVariable","ruleset":"Naming Rules","priority":1,
 "description":"Avoid excessively long variable names like $searchCriteriaBuilder."}]}]}
JSON
exit 2
STUB

# --- stub phpstan: a CRASHED run — files is a LIST, with the reason in "errors" --------------
cat > "$BIN/phpstan" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"totals":{"errors":1,"file_errors":0},"files":[],
 "errors":["Child process error: PHPStan process crashed because it reached configured PHP memory limit: 128M"]}
JSON
exit 1
STUB

chmod +x "$BIN/phpcs" "$BIN/phpmd" "$BIN/phpstan"

FINDINGS="$WORK/findings.json"
ERRLOG="$WORK/stderr.txt"

TARGET_PATH="$MOD" SCOPE=module RUNNER="" \
PHPCS="$BIN/phpcs" PHPMD="$BIN/phpmd" PHPSTAN="$BIN/phpstan" RECTOR="" \
FINDINGS_FILE="$FINDINGS" \
    bash "$SCRIPT" >/dev/null 2>"$ERRLOG"

[ -f "$FINDINGS" ] || { echo "FAIL: no findings file produced"; exit 1; }

RESULT="$(FINDINGS="$FINDINGS" ERRLOG="$ERRLOG" python3 <<'PY'
import json
import os
import sys

findings = json.load(open(os.environ['FINDINGS'], encoding='utf-8'))
stderr = open(os.environ['ERRLOG'], encoding='utf-8', errors='replace').read()
fail = []


def by(prefix):
    return [f for f in findings if str(f.get('id', '')).startswith(prefix)]


# 1. phpcs — the deprecation preamble must not cost us the report.
phpcs = by('quality-phpcs-')
if len(phpcs) != 2:
    fail.append(f'phpcs: expected 2 findings through the DEPRECATED preamble, got {len(phpcs)}')
elif not any('Real error here' in (f.get('title') or '') for f in phpcs):
    fail.append('phpcs: parsed, but the ERROR message did not survive')

# 2. phpmd — violations nested under files must be read.
phpmd = by('quality-phpmd-')
if len(phpmd) != 1:
    fail.append(f'phpmd: expected 1 finding from the files[].violations[] shape, got {len(phpmd)}')
else:
    ev = (phpmd[0].get('evidence') or [{}])[0]
    if ev.get('file') != '/m/A.php':
        fail.append(f"phpmd: fileName not taken from the parent file key, got {ev.get('file')!r}")
    # 3. A lint rule must never be Critical — magento2-audit fails its verdict on any Critical.
    if phpmd[0].get('severity') == 'critical':
        fail.append('phpmd: priority 1 mapped to critical; a style rule must not block a release')

# 4. phpstan — a crashed run (files: []) must not raise, and its reason must reach stderr.
if 'memory limit' not in stderr:
    fail.append('phpstan: run-level crash text was not surfaced to stderr')

# 5. stderr is the ONLY channel that becomes scanner_errors — it must carry the tool diagnostics.
if 'run-analysis/phpstan' not in stderr:
    fail.append('tool stderr was not forwarded; scanner_errors would be empty on failure')

print('\n'.join(fail) if fail else 'OK')
PY
)"

if [ "$RESULT" = "OK" ]; then
    echo "PASS: static-analysis parsers read each tool's real output and forward tool stderr"
    exit 0
fi

echo "FAIL:"
echo "$RESULT"
echo "--- stderr captured ---"
cat "$ERRLOG"
exit 1
