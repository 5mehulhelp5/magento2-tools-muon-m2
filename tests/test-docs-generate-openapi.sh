#!/usr/bin/env bash
# The generated openapi.yaml describes exactly the routes etc/webapi.xml declares:
# right version, right paths, right methods, `:param` rewritten to `{param}` — plus
# the byte-identical-on-rerun guarantee that makes the artifact reviewable in a PR.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

. tests/lib/docs-api-artifacts.sh
docs_api_workdir
trap 'rm -rf "$DA_WORK"' EXIT
docs_api_generate || exit 1

if [ "$DA_RC" -ne 0 ]; then
    echo "FAIL: emitter exited $DA_RC"; cat "$DA_WORK/emit.err"; exit 1
fi

python3 - "$DA_API_DIR/openapi.yaml" "$DA_MODULE/etc/webapi.xml" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, 'tests/lib')
import yaml_subset

spec_path, webapi_path = sys.argv[1], sys.argv[2]

def need(cond, msg):
    if not cond:
        print('FAIL:', msg)
        sys.exit(1)

try:
    doc = yaml_subset.load(open(spec_path, encoding='utf-8').read())
except yaml_subset.YamlSubsetError as exc:
    print('FAIL: openapi.yaml does not parse:', exc)
    sys.exit(1)

need(doc.get('openapi') == '3.1.0', 'openapi version is %r, want 3.1.0' % doc.get('openapi'))
need(isinstance(doc.get('info'), dict) and doc['info'].get('title'), 'info.title missing')
# composer.json for the fixture carries no `version`; the skill must omit the key
# rather than invent one.
need('version' not in doc['info'], 'info.version invented from a composer.json with none')

servers = doc.get('servers') or []
need(len(servers) == 1, 'expected exactly one templated server entry')
need(servers[0]['url'] == 'https://{host}/rest/{store}',
     'server url is not the templated form: %r' % servers[0]['url'])
need(servers[0]['variables']['host']['default'] == 'magento.test',
     'server host default is not magento.test')

# --- every <route> in the XML must appear as a paths entry, and vice versa ---
declared = set()
for route in ET.parse(webapi_path).getroot().findall('.//route'):
    url = route.get('url', '')
    declared.add((re.sub(r':(\w+)', r'{\1}', url), route.get('method', '').lower()))
emitted = {(path, method)
           for path, item in (doc.get('paths') or {}).items()
           for method in item}
need(declared == emitted,
     'paths/webapi.xml mismatch\n  only in webapi.xml: %s\n  only in openapi.yaml: %s'
     % (sorted(declared - emitted), sorted(emitted - declared)))

# --- `:param` became `{param}`, and each is a required path parameter ---
need(not any(':' in p for p in doc['paths']), 'a raw `:param` survived into paths')
op = doc['paths']['/V1/acme-sample/{id}']['get']
params = op.get('parameters') or []
need(params == [{'name': 'id', 'in': 'path', 'required': True,
                 'schema': {'type': 'integer'}}],
     'path parameter not emitted/typed: %r' % params)

# --- operationIds are derived and stable ---
ids = [item[m]['operationId'] for item in doc['paths'].values() for m in item]
need(len(ids) == len(set(ids)), 'operationIds are not unique: %r' % ids)
need(op['operationId'] == 'sampleRepositoryInterfaceGetById',
     'operationId not {serviceClassShortName}_{method} camelCased: %r' % op['operationId'])

# --- error model ---
need(doc['components']['schemas']['Error']['properties'].keys() >= {'message'},
     'Error component missing the Magento envelope')
need('404' in op['responses'], '@throws NoSuchEntityException did not map to 404')
need(op['responses']['404']['content']['application/json']['schema']['$ref']
     == '#/components/schemas/Error', '404 does not reference the Error component')
print('PASS: openapi')
PY
[ $? -eq 0 ] || exit 1

# --- idempotence (spec 12.3): a second run must be byte-identical ---
cp -r "$DA_API_DIR" "$DA_WORK/run1"
docs_api_generate || exit 1
if ! diff -r "$DA_WORK/run1" "$DA_API_DIR" >/dev/null 2>&1; then
    echo "FAIL: a second run on an unchanged module produced different bytes"
    diff -r "$DA_WORK/run1" "$DA_API_DIR" | head -20
    exit 1
fi
echo "PASS: idempotent across two runs"
exit 0
