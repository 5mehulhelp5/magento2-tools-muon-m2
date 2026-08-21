#!/usr/bin/env bash
# A getList route takes Magento\Framework\Api\SearchCriteriaInterface — a type the
# module-local DTO walker cannot reach, so it would otherwise degrade to a `string`
# request body that does not exist. The operation must instead reference the shared
# searchCriteria query parameters, and the reference doc and the emitter must name the
# same set.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

. tests/lib/docs-api-artifacts.sh
docs_api_workdir
trap 'rm -rf "$DA_WORK"' EXIT
docs_api_generate || exit 1
[ "$DA_RC" -eq 0 ] || { echo "FAIL: emitter exited $DA_RC"; cat "$DA_WORK/emit.err"; exit 1; }

python3 - "$DA_API_DIR/openapi.yaml" \
          "$DA_API_DIR/postman/acme-sample.postman_collection.json" <<'PY'
import json
import re
import sys

sys.path.insert(0, 'tests/lib')
import yaml_subset

doc = yaml_subset.load(open(sys.argv[1], encoding='utf-8').read())
collection = json.load(open(sys.argv[2], encoding='utf-8'))

def need(cond, msg):
    if not cond:
        print('FAIL:', msg)
        sys.exit(1)

op = doc['paths']['/V1/acme-sample/search']['get']

need('requestBody' not in op,
     'a SearchCriteria route must not carry a request body')
need('"type": "string"' not in json.dumps(op.get('parameters') or []),
     'SearchCriteria parameters must be $ref-ed, not inlined as string params')

refs = [p.get('$ref') for p in op['parameters']]
need(all(r and r.startswith('#/components/parameters/') for r in refs),
     'operation parameters are not all $refs: %r' % refs)
names = [r.rsplit('/', 1)[1] for r in refs]

declared = doc['components']['parameters']
need(set(names) == set(declared),
     'operation refs and components/parameters disagree: %r vs %r'
     % (sorted(names), sorted(declared)))

# The canonical Magento query shape, spelled out.
expected_query = {
    'searchCriteria[filterGroups][0][filters][0][field]',
    'searchCriteria[filterGroups][0][filters][0][value]',
    'searchCriteria[filterGroups][0][filters][0][conditionType]',
    'searchCriteria[sortOrders][0][field]',
    'searchCriteria[sortOrders][0][direction]',
    'searchCriteria[pageSize]',
    'searchCriteria[currentPage]',
}
actual_query = {p['name'] for p in declared.values()}
need(actual_query == expected_query,
     'query parameter names differ: %r' % sorted(actual_query ^ expected_query))
for name, param in declared.items():
    need(param['in'] == 'query', '%s is not in: query' % name)
    need(param['required'] is False, '%s must not be required' % name)
need(declared['searchCriteriaPageSize']['schema']['type'] == 'integer',
     'pageSize must be an integer')

# Declared once, not repeated per operation.
need(len(declared) == 7, 'expected 7 shared parameters, got %d' % len(declared))

# --- the Postman request carries the same parameters as (disabled) query entries ---
def find(items):
    for item in items:
        if 'item' in item:
            hit = find(item['item'])
            if hit:
                return hit
        elif '/V1/acme-sample/search' in item['request']['url']['raw']:
            return item
    return None

request = find(collection['item'])
need(request is not None, 'the search route is missing from the Postman collection')
need({q['key'] for q in request['request']['url']['query']} == expected_query,
     'Postman query parameters differ from the OpenAPI set')

# --- drift guard: the reference doc and the emitter must name the same components ---
ref_text = open('skills/magento2-docs-generate/references/search-criteria-params.md',
                encoding='utf-8').read()
block = re.search(r'```search-criteria-params\n(.*?)```', ref_text, re.S)
need(block is not None,
     'references/search-criteria-params.md has no ```search-criteria-params block')
documented = {line.strip() for line in block.group(1).splitlines() if line.strip()}
need(documented == set(declared),
     'reference doc and emitter disagree on the parameter set: %r'
     % sorted(documented ^ set(declared)))

emitter = open('skills/magento2-docs-generate/scripts/emit-api-artifacts.sh',
               encoding='utf-8').read()
for name in expected_query:
    need(name in emitter, 'emitter no longer emits %s' % name)
print('PASS: searchCriteria')
PY
