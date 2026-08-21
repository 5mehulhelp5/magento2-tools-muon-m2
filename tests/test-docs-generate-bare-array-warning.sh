#!/usr/bin/env bash
# A bare `@param array` anywhere in the reachable Api/ graph makes Magento's own
# TypeProcessor refuse the type, and GET /rest/<store>/schema then returns HTTP 500 for
# EVERY service on the installation — not just this module. Nothing else in the toolchain
# reports that, so the preflight must name the file and line, loudly. It is a warning,
# not a stop: the emitted spec is still useful, the affected property just degrades.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

. tests/lib/docs-api-artifacts.sh
docs_api_workdir
trap 'rm -rf "$DA_WORK"' EXIT
docs_api_generate || exit 1

FAIL=0
if [ "$DA_RC" -ne 0 ]; then
    echo "FAIL: a bare-array warning must not stop the run (exit $DA_RC)"
    cat "$DA_WORK/emit.err"; FAIL=1
fi
[ -f "$DA_API_DIR/openapi.yaml" ] || { echo "FAIL: the run must still emit openapi.yaml"; FAIL=1; }

python3 - "$DA_REPORT" "$DA_MODULE" "$DA_API_DIR/openapi.yaml" <<'PY' || FAIL=1
import os
import sys

sys.path.insert(0, 'tests/lib')
import json
import yaml_subset

report = json.load(open(sys.argv[1], encoding='utf-8'))
module_path, spec_path = sys.argv[2], sys.argv[3]

def need(cond, msg):
    if not cond:
        print('FAIL:', msg)
        sys.exit(1)

warnings = report.get('warnings') or []
need(warnings, 'the bare `array` annotation produced no warning')

hit = [w for w in warnings if w['annotation'] == '@param array $context']
need(hit, 'the bare `@param array $context` was not reported: %r'
     % [w['annotation'] for w in warnings])
warning = hit[0]

need(warning['file'] == 'Api/Data/SampleInterface.php',
     'warning names the wrong file: %r' % warning['file'])
need(isinstance(warning['line'], int) and warning['line'] > 0,
     'warning carries no usable line number: %r' % warning.get('line'))

# The line must actually be the offending one, not an approximation.
with open(os.path.join(module_path, warning['file']), encoding='utf-8') as fh:
    source = fh.readlines()
need('@param array $context' in source[warning['line'] - 1],
     'line %d of %s is not the offending annotation: %r'
     % (warning['line'], warning['file'], source[warning['line'] - 1].strip()))

# The message has to explain the blast radius, or it reads as a style nit.
message = warning['message']
for fragment in ('TypeProcessor', 'HTTP 500', 'EVERY service'):
    need(fragment in message, 'warning message omits %r: %r' % (fragment, message))

need(any('bare `array`' in f for f in report.get('followups') or []),
     'the run report must carry the bare-array fix as a follow-up')

# `array` that a `@return Foo[]` docblock types is Magento's own SearchResults idiom
# and must NOT warn — otherwise every getList route in every module cries wolf.
need(not [w for w in warnings if 'getItems' in w['annotation']],
     'a docblock-typed `array` was wrongly reported: %r'
     % [w['annotation'] for w in warnings])
doc = yaml_subset.load(open(spec_path, encoding='utf-8').read())
items = doc['components']['schemas']['SampleSearchResults']['properties']['items']
need(items.get('type') == 'array' and items['items']['$ref'].endswith('/Sample'),
     'the docblock-typed collection lost its element type: %r' % items)

print('  ok  warning names file+line, explains the blast radius, run completed')
PY

if [ "$FAIL" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "PASS: bare array warning"
exit 0
