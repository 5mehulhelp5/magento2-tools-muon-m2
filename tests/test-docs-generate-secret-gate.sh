#!/usr/bin/env bash
# The blocking secret/privacy gate (spec section 7).
#
# Phase A — the structural rule (assertion 9): examples derive only from schema types,
#   so secrets sitting in the module's own runtime files must not reach the output even
#   when the run is clean.
# Phase B — the backstops: a value that DOES reach a generated file through a real
#   channel (composer.json flows into info.description) must block that file's write
#   and be reported, rule by rule.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

. tests/lib/docs-api-artifacts.sh
FAIL=0

# ---------------------------------------------------------------------------
# Phase A — a clean run never widens its inputs
# ---------------------------------------------------------------------------
docs_api_workdir
WORK_A="$DA_WORK"
mkdir -p "$DA_MODULE/var/log" "$DA_MODULE/app/etc"
# Values that exist on a real install and must never be read, let alone emitted.
printf 'admin bearer eyJhbGciOiJIUzI1NiJ9.cGhhbnRvbQ.sig\n' > "$DA_MODULE/var/log/system.log"
printf "<?php return ['crypt' => ['key' => 'AKIAIOSFODNN7EXAMPLE']];\n" > "$DA_MODULE/app/etc/env.php"
printf 'MAGENTO_ADMIN_PASSWORD=hunter2\n' > "$DA_MODULE/.env"
printf '{"http-basic":{"repo.magento.com":{"password":"hunter2"}}}\n' > "$DA_MODULE/auth.json"
# Tainted constants ON THE DTO ITSELF — the closest a real module gets to a "default".
# Examples derive from the Example-Derivation Table, i.e. from TYPES, so a constant's
# value has no path into the output. That is rule 9 stated as a test rather than a claim.
python3 - "$DA_MODULE/Api/Data/SampleInterface.php" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as fh:
    source = fh.read()
constants = '''
    public const DEFAULT_DOWNLOAD_URL =
        'https://cdn.example.net/f?X-Amz-Signature=deadbeef';
    public const DEFAULT_TOKEN = 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJleGFtcGxlIn0.';
    public const OWNER_EMAIL = 'ops@example.com';
    public const BUCKET_KEY = 'AKIAIOSFODNN7EXAMPLE';
'''
marker = 'interface SampleInterface\n{\n'
assert source.count(marker) == 1, 'fixture shape changed'
with open(path, 'w', encoding='utf-8') as fh:
    fh.write(source.replace(marker, marker + constants, 1))
PY

docs_api_generate || exit 1
if [ "$DA_RC" -ne 0 ]; then
    echo "FAIL(A): a clean module must emit cleanly, got exit $DA_RC"
    cat "$DA_WORK/emit.err"; FAIL=1
fi
if grep -rlE 'hunter2|AKIAIOSFODNN7EXAMPLE|eyJhbGciOiJ|X-Amz-Signature|ops@example\.com|cdn\.example\.net' \
        "$DA_API_DIR" >/dev/null 2>&1; then
    echo "FAIL(A): a secret from the module tree or a DTO constant reached the artifacts"
    grep -rlE 'hunter2|AKIAIOSFODNN7EXAMPLE|eyJhbGciOiJ|X-Amz-Signature|ops@example\.com|cdn\.example\.net' "$DA_API_DIR"
    FAIL=1
fi
if [ -e "$DA_API_DIR/http-client.private.env.json" ]; then
    echo "FAIL(A): the private env file must never be generated"; FAIL=1
fi
python3 - "$DA_API_DIR" <<'PY' || FAIL=1
import json
import os
import re
import sys

api_dir = sys.argv[1]
secretish = re.compile(r'(?i)(token|secret|key|password|credential)')
problems = []
for name in ('http-client.env.json',):
    with open(os.path.join(api_dir, name), encoding='utf-8') as fh:
        for env in json.load(fh).values():
            for key, value in env.items():
                if secretish.search(key) and value:
                    problems.append('%s: %s=%r' % (name, key, value))
env_path = [os.path.join(dp, f) for dp, _d, fs in os.walk(api_dir) for f in fs
            if f.endswith('.postman_environment.json')]
for path in env_path:
    with open(path, encoding='utf-8') as fh:
        for entry in json.load(fh)['values']:
            if entry.get('type') == 'secret' and entry.get('value'):
                problems.append('%s: %s=%r' % (os.path.basename(path),
                                               entry['key'], entry['value']))
            if secretish.search(entry['key']) and entry.get('value'):
                problems.append('%s: %s=%r' % (os.path.basename(path),
                                               entry['key'], entry['value']))
            if secretish.search(entry['key']) and entry.get('type') != 'secret':
                problems.append('%s: %s not typed secret' % (os.path.basename(path),
                                                             entry['key']))
if problems:
    print('FAIL(A): secret-named variables must ship empty and secret-typed:')
    for p in problems:
        print('   ', p)
    sys.exit(1)
print('  ok  (A) no runtime secret reached the artifacts; secret vars ship empty')
PY
rm -rf "$WORK_A"

# ---------------------------------------------------------------------------
# Phase B — a tainted value that DOES reach a generated file blocks its write
# ---------------------------------------------------------------------------
docs_api_workdir
trap 'rm -rf "$DA_WORK"' EXIT
python3 - "$DA_MODULE/composer.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as fh:
    data = json.load(fh)
# Every value here is synthetic. AKIAIOSFODNN7EXAMPLE is the key AWS itself uses in
# its documentation; the JWT decodes to {"alg":"none"}/{"sub":"example"}.
data['description'] = (
    'Sample module. Contact ops@example.com. '
    'Call it with Bearer abcdefgh12345678 or the token '
    'eyJhbGciOiJub25lIn0.eyJzdWIiOiJleGFtcGxlIn0. — the bucket key is '
    'AKIAIOSFODNN7EXAMPLE and downloads come from '
    'https://shop.example.com/f?X-Amz-Signature=deadbeef'
)
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=4)
PY

docs_api_generate || exit 1
if [ "$DA_RC" -ne 2 ]; then
    echo "FAIL(B): a tainted artifact must exit 2 (blocked), got $DA_RC"
    cat "$DA_WORK/emit.err"; FAIL=1
fi
if [ -e "$DA_API_DIR/openapi.yaml" ]; then
    echo "FAIL(B): the blocked file must not be written"; FAIL=1
fi
python3 - "$DA_REPORT" <<'PY' || FAIL=1
import json
import sys

report = json.load(open(sys.argv[1], encoding='utf-8'))
blocked = report.get('blocked') or []
if not blocked:
    print('FAIL(B): nothing was reported as blocked')
    sys.exit(1)
by_rule = {b['rule']: b for b in blocked}
files = {b['file'] for b in blocked}
missing = []
for rule in ('credential-literal', 'jwt-shape', 'aws-key',
             'concrete-host', 'personal-identifier'):
    if rule not in by_rule:
        missing.append(rule)
if missing:
    print('FAIL(B): these gate rules did not fire:', missing)
    print('   reported:', sorted(by_rule))
    sys.exit(1)
if files != {'openapi.yaml'}:
    print('FAIL(B): only openapi.yaml carries the tainted value, got', sorted(files))
    sys.exit(1)
for rule, entry in by_rule.items():
    if not entry.get('match'):
        print('FAIL(B): %s reported no matched text' % rule)
        sys.exit(1)
# The untainted artifacts still ship — the gate blocks per file, not per run.
written = set(report['written'])
if not any(p.endswith('.http') for p in written):
    print('FAIL(B): the clean artifacts must still be written; got', sorted(written))
    sys.exit(1)
print('  ok  (B) every rule fired, the tainted file was withheld, the rest shipped')
PY

if [ "$FAIL" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "PASS: secret gate"
exit 0
