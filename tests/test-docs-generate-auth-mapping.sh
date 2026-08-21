#!/usr/bin/env bash
# webapi.xml's <resources> drive the OpenAPI security selection:
#   anonymous -> no credentials at all
#   self      -> customerBearer (a customer token, never an admin one)
#   anything else -> admin/integration bearer + x-magento-acl naming the resources,
#                    so the spec stays traceable back to the XML.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

. tests/lib/docs-api-artifacts.sh
docs_api_workdir
trap 'rm -rf "$DA_WORK"' EXIT
docs_api_generate || exit 1
[ "$DA_RC" -eq 0 ] || { echo "FAIL: emitter exited $DA_RC"; cat "$DA_WORK/emit.err"; exit 1; }

python3 - "$DA_API_DIR/openapi.yaml" "$DA_API_DIR/acme-sample.http" <<'PY'
import sys

sys.path.insert(0, 'tests/lib')
import yaml_subset

doc = yaml_subset.load(open(sys.argv[1], encoding='utf-8').read())
http_text = open(sys.argv[2], encoding='utf-8').read()

def need(cond, msg):
    if not cond:
        print('FAIL:', msg)
        sys.exit(1)

anon = doc['paths']['/V1/acme-sample/external/{id}']['get']
me = doc['paths']['/V1/acme-sample/me']['get']
acl = doc['paths']['/V1/acme-sample/{id}']['get']

# `security: []` is the explicit "this operation takes no credentials" form. An
# absent key would mean "inherit the document default", which is not the same claim.
need(anon.get('security') == [], 'anonymous route must carry an empty security list')
need('x-magento-acl' not in anon, 'anonymous route must not carry x-magento-acl')
need('401' not in anon['responses'], 'anonymous route must not document a 401')

need(me.get('security') == [{'customerBearer': []}],
     'self route must select customerBearer only: %r' % me.get('security'))
need('x-magento-acl' not in me, 'self route must not carry x-magento-acl')
need('401' in me['responses'], 'self route must document a 401')

need(acl.get('security') == [{'adminBearer': []}, {'integrationBearer': []}],
     'ACL route must select admin/integration bearer: %r' % acl.get('security'))
need(acl.get('x-magento-acl') == ['Acme_Sample::view'],
     'x-magento-acl does not mirror <resource ref>: %r' % acl.get('x-magento-acl'))
need('403' in acl['responses'], 'ACL route must document a 403')

schemes = doc['components']['securitySchemes']
need(set(schemes) == {'adminBearer', 'customerBearer', 'integrationBearer'},
     'unexpected securitySchemes: %r' % sorted(schemes))
for name, scheme in schemes.items():
    need(scheme['type'] == 'http' and scheme['scheme'] == 'bearer'
         and scheme['bearerFormat'] == 'JWT',
         '%s is not http/bearer/JWT' % name)

# --- the .http file makes the same distinction ---
blocks = [b for b in http_text.split('\n###') if b.strip()]
anon_block = [b for b in blocks if '/V1/acme-sample/external/' in b][0]
need('Authorization:' not in anon_block,
     'the anonymous .http block must omit Authorization entirely')
authed = [b for b in blocks if '/V1/acme-sample/me' in b][0]
need('Authorization: Bearer {{authToken}}' in authed,
     'a non-anonymous .http block must send Authorization: Bearer {{authToken}}')
print('PASS: auth mapping')
PY
