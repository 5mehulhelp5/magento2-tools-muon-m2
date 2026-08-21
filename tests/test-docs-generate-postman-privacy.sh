#!/usr/bin/env bash
# Postman injects personal identifiers on export (_postman_exported_by, a numeric user
# id) and a random collection id. Neither is API description: the first leaks who ran
# the export, the second makes every regeneration a full-file diff. The generated
# collection must carry neither.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

. tests/lib/docs-api-artifacts.sh
docs_api_workdir
trap 'rm -rf "$DA_WORK"' EXIT

docs_api_generate || exit 1
[ "$DA_RC" -eq 0 ] || { echo "FAIL: emitter exited $DA_RC"; cat "$DA_WORK/emit.err"; exit 1; }
RUN1="$DA_WORK/run1"
cp -r "$DA_API_DIR/postman" "$RUN1"
KEEP="$DA_WORK"

# Run again from a DIFFERENT temp directory: the id must derive from the module
# identity, not from the path, the clock, or a random source.
docs_api_workdir
trap 'rm -rf "$KEEP" "$DA_WORK"' EXIT
docs_api_generate || exit 1
[ "$DA_RC" -eq 0 ] || { echo "FAIL: second run exited $DA_RC"; exit 1; }

FAIL=0
if ! diff -r "$RUN1" "$DA_API_DIR/postman" >/dev/null 2>&1; then
    echo "FAIL: the Postman files are not byte-identical across runs in different paths"
    diff -r "$RUN1" "$DA_API_DIR/postman" | head -20
    FAIL=1
fi

python3 - "$DA_API_DIR/postman/acme-sample.postman_collection.json" \
          "$DA_API_DIR/postman/acme-sample.postman_environment.json" <<'PY' || FAIL=1
import json
import re
import sys
import uuid

collection_path, environment_path = sys.argv[1], sys.argv[2]
collection_text = open(collection_path, encoding='utf-8').read()
environment_text = open(environment_path, encoding='utf-8').read()
collection = json.loads(collection_text)
environment = json.loads(environment_text)

def need(cond, msg):
    if not cond:
        print('FAIL:', msg)
        sys.exit(1)

for banned in ('_postman_exported_by', '_postman_exported_using'):
    need(banned not in collection_text, '%s must never be generated' % banned)
    need(banned not in environment_text, '%s must never be generated' % banned)

email = re.compile(r'[\w.+-]+@[\w-]+\.\w+')
need(not email.search(collection_text), 'an email address leaked into the collection')
need(not email.search(environment_text), 'an email address leaked into the environment')

pid = collection['info']['_postman_id']
need(uuid.UUID(pid).version == 5,
     '_postman_id must be a deterministic UUIDv5, got version %s' % uuid.UUID(pid).version)
need(collection['info']['schema'].endswith('collection/v2.1.0/collection.json'),
     'collection is not declared as schema v2.1')

secretish = re.compile(r'(?i)(token|secret|key|password|credential)')
saw_secret = False
for entry in environment['values']:
    if entry.get('type') == 'secret':
        saw_secret = True
        need(entry['value'] == '', '%s ships a non-empty secret value' % entry['key'])
    if secretish.search(entry['key']):
        need(entry.get('type') == 'secret',
             '%s is secret-named but not typed secret' % entry['key'])
        need(entry['value'] == '', '%s ships a non-empty value' % entry['key'])
need(saw_secret, 'the environment declares no secret-typed variable at all')

# Collection-level bearer auth references the variable, never a literal.
bearer = collection['auth']['bearer']
need(collection['auth']['type'] == 'bearer', 'collection auth is not bearer')
need(any(b['value'] == '{{authToken}}' for b in bearer),
     'collection auth must reference {{authToken}}, not a literal token')
print('  ok  no personal identifiers, stable id, empty secrets')
PY

if [ "$FAIL" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "PASS: postman privacy"
exit 0
