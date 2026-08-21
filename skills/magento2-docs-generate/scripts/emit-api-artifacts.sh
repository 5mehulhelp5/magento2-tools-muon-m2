#!/usr/bin/env bash
# emit-api-artifacts.sh — render machine-readable REST API description artifacts
# from the surface JSON produced by extract-surface.sh.
#
# Emits, under {MODULE_PATH}/docs/api/ (never {MODULE_PATH}/api/ — see the directory
# rule below):
#
#   openapi.yaml                          OpenAPI 3.1
#   {slug}.http                           JetBrains HTTP Client
#   http-client.env.json                  public env — NO secret values
#   postman/{slug}.postman_collection.json    Collection v2.1
#   postman/{slug}.postman_environment.json   placeholders only
#
# The script is deterministic: two runs on an unchanged module produce byte-identical
# files (no timestamps, no random ids — the Postman collection id is a UUIDv5 derived
# from {Vendor}_{Module}).
#
# It reads ONLY the module's own files, the surface JSON, and the skill templates. It
# never reads var/log/, .env, app/etc/env.php, auth.json, or any live HTTP response,
# and it never writes a .php/.xml/.phtml/.less/.js/.graphqls file.
#
# DIRECTORY RULE (non-negotiable): every module with a REST surface already has
# {module}/Api/. On a case-insensitive filesystem — macOS default, Windows, any
# unpacked .zip — {module}/api/ IS {module}/Api/, so writing one corrupts the PSR-4
# tree and breaks autoloading. Output therefore nests under {module}/docs/api/, and
# the gate asserts {module}/api/ was not created.
#
# Usage:
#   MODULE_PATH=/path/to/app/code/Acme/Sample SURFACE_FILE=/tmp/surface.json \
#       bash emit-api-artifacts.sh
#
# Inputs (env vars):
#   MODULE_PATH   Module root (required).
#   SURFACE_FILE  Surface JSON from extract-surface.sh (required).
#   FORMATS       Comma list of openapi,http-client,postman (default: all three).
#   OUTPUT_DIR    Default: {MODULE_PATH}/docs/api
#   TEMPLATE_DIR  Default: <script dir>/../templates
#   REPORT_FILE   Optional path for the JSON run report (also printed to stdout).
#
# Exit codes:
#   0  every selected artifact written (warnings may still be present)
#   2  at least one artifact was BLOCKED by the secret/privacy gate
#   1  hard error (bad input, missing template, unwritable output)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODULE_PATH="${MODULE_PATH:-${1:-}}"
: "${MODULE_PATH:?MODULE_PATH is required (pass as env var or \$1)}"
: "${SURFACE_FILE:?SURFACE_FILE is required (surface JSON from extract-surface.sh)}"

if [ ! -d "$MODULE_PATH" ]; then
    echo "emit-api-artifacts: module directory does not exist: $MODULE_PATH" >&2
    exit 1
fi
if [ ! -f "$SURFACE_FILE" ]; then
    echo "emit-api-artifacts: surface JSON not found: $SURFACE_FILE" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "emit-api-artifacts: python3 is required but not found on PATH" >&2
    exit 1
fi

FORMATS="${FORMATS:-openapi,http-client,postman}"
OUTPUT_DIR="${OUTPUT_DIR:-${MODULE_PATH}/docs/api}"
TEMPLATE_DIR="${TEMPLATE_DIR:-${SCRIPT_DIR}/../templates}"
REPORT_FILE="${REPORT_FILE:-}"

MODULE_PATH="$MODULE_PATH" SURFACE_FILE="$SURFACE_FILE" FORMATS="$FORMATS" \
OUTPUT_DIR="$OUTPUT_DIR" TEMPLATE_DIR="$TEMPLATE_DIR" REPORT_FILE="$REPORT_FILE" \
python3 - <<'PY'
import json
import os
import re
import sys
import uuid

module_path = os.environ['MODULE_PATH']
surface_file = os.environ['SURFACE_FILE']
formats = {f.strip() for f in os.environ['FORMATS'].split(',') if f.strip()}
output_dir = os.environ['OUTPUT_DIR']
template_dir = os.environ['TEMPLATE_DIR']
report_file = os.environ['REPORT_FILE']

with open(surface_file, encoding='utf-8') as fh:
    surface = json.load(fh)
routes = surface.get('surfaces', {}).get('rest_routes', []) or []
warnings = surface.get('surfaces', {}).get('rest_warnings', []) or []

# ---------------------------------------------------------------------------
# Module identity
# ---------------------------------------------------------------------------
_parts = os.path.normpath(os.path.abspath(module_path)).split(os.sep)
VENDOR, MODULE = (_parts[-2], _parts[-1]) if len(_parts) >= 2 else ('Vendor', 'Module')

def _composer():
    fpath = os.path.join(module_path, 'composer.json')
    if not os.path.isfile(fpath):
        return {}
    try:
        with open(fpath, encoding='utf-8', errors='replace') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}

COMPOSER = _composer()

def _kebab(text):
    text = re.sub(r'(?<!^)(?=[A-Z])', '-', text)
    return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')

VERSION_SEG_RE = re.compile(r'^[Vv]\d+$')

def compute_slug():
    """Returns (slug, prefix_segments).

    1. longest common literal path-segment prefix after the version segment;
    2. else composer `name` with vendor and a `module-` prefix stripped;
    3. else {vendor}-{module} kebab-cased.

    `prefix_segments` is the URL prefix the slug came from — empty for the
    fallbacks — so Postman folder grouping strips real path segments rather than
    the slug's kebab words (`acme-sample` is ONE segment, not two).
    """
    seg_lists = []
    for r in routes:
        segs = [s for s in (r.get('url_template') or '').strip('/').split('/') if s]
        if segs and VERSION_SEG_RE.match(segs[0]):
            segs = segs[1:]
        if segs:
            seg_lists.append(segs)
    prefix = []
    if seg_lists:
        for i in range(min(len(s) for s in seg_lists)):
            candidate = seg_lists[0][i]
            if candidate.startswith('{'):
                break
            if all(s[i] == candidate for s in seg_lists):
                prefix.append(candidate)
            else:
                break
    if prefix:
        return '-'.join(prefix), prefix
    name = COMPOSER.get('name') or ''
    if '/' in name:
        pkg = name.split('/', 1)[1]
        pkg = pkg[len('module-'):] if pkg.startswith('module-') else pkg
        if pkg:
            return pkg, []
    return '%s-%s' % (_kebab(VENDOR), _kebab(MODULE)), []

SLUG, SLUG_SEGMENTS = compute_slug()

# ---------------------------------------------------------------------------
# YAML — a deliberately small block-style subset: 2-space indent, block maps and
# sequences, JSON-quoted scalars. No anchors, no folded scalars, no flow style
# beyond the empty `{}` / `[]` forms.
# ---------------------------------------------------------------------------
PLAIN_KEY_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_.-]*$')

def _yk(key):
    key = str(key)
    return key if PLAIN_KEY_RE.match(key) else json.dumps(key)

def _ys(value):
    if value is True:
        return 'true'
    if value is False:
        return 'false'
    if value is None:
        return 'null'
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    return json.dumps(str(value), ensure_ascii=False)

def _ymap(obj, indent):
    lines = []
    pad = '  ' * indent
    for key, value in obj.items():
        k = _yk(key)
        if isinstance(value, dict):
            if value:
                lines.append('%s%s:' % (pad, k))
                lines.extend(_ymap(value, indent + 1))
            else:
                lines.append('%s%s: {}' % (pad, k))
        elif isinstance(value, list):
            if value:
                lines.append('%s%s:' % (pad, k))
                lines.extend(_yseq(value, indent + 1))
            else:
                lines.append('%s%s: []' % (pad, k))
        else:
            lines.append('%s%s: %s' % (pad, k, _ys(value)))
    return lines

def _yseq(seq, indent):
    lines = []
    pad = '  ' * indent
    for item in seq:
        if isinstance(item, dict) and item:
            sub = _ymap(item, indent + 1)
            lines.append('%s- %s' % (pad, sub[0].lstrip()))
            lines.extend(sub[1:])
        elif isinstance(item, list) and item:
            sub = _yseq(item, indent + 1)
            lines.append('%s- %s' % (pad, sub[0].lstrip()))
            lines.extend(sub[1:])
        elif isinstance(item, dict):
            lines.append('%s- {}' % pad)
        elif isinstance(item, list):
            lines.append('%s- []' % pad)
        else:
            lines.append('%s- %s' % (pad, _ys(item)))
    return lines

def yaml_block(key, value):
    """Render one top-level `key: value` block."""
    return '\n'.join(_ymap({key: value}, 0))

def jdump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False)

# ---------------------------------------------------------------------------
# Schema hoisting — a titled object schema becomes a named component + $ref
# ---------------------------------------------------------------------------
COMPONENT_SCHEMAS = {}

def _register(title, body):
    name = title
    suffix = 1
    while name in COMPONENT_SCHEMAS and COMPONENT_SCHEMAS[name] != body:
        suffix += 1
        name = '%s%d' % (title, suffix)
    COMPONENT_SCHEMAS[name] = body
    return name

def hoist(node):
    if not isinstance(node, dict):
        return node
    if node.get('type') == 'array' and 'items' in node:
        out = dict(node)
        out['items'] = hoist(node['items'])
        return out
    if node.get('type') == 'object' and node.get('title'):
        body = {'type': 'object',
                'properties': {k: hoist(v) for k, v in (node.get('properties') or {}).items()}}
        ref = {'$ref': '#/components/schemas/%s' % _register(node['title'], body)}
        if node.get('nullable'):
            ref['nullable'] = True
        return ref
    return node

# ---------------------------------------------------------------------------
# SearchCriteria — the canonical Magento query parameters. Kept here as the single
# source of truth; references/search-criteria-params.md documents the same set and
# test-docs-generate-searchcriteria.sh asserts the two agree.
# ---------------------------------------------------------------------------
SEARCH_CRITERIA_PARAMS = [
    ('searchCriteriaFilterField',
     'searchCriteria[filterGroups][0][filters][0][field]', 'string',
     'Field the filter applies to. Filters inside one filter group are OR-ed; '
     'separate groups are AND-ed.'),
    ('searchCriteriaFilterValue',
     'searchCriteria[filterGroups][0][filters][0][value]', 'string',
     'Value to compare against. Use `%` as the wildcard with `conditionType=like`.'),
    ('searchCriteriaFilterConditionType',
     'searchCriteria[filterGroups][0][filters][0][conditionType]', 'string',
     'Comparison operator: `eq`, `neq`, `like`, `nlike`, `in`, `nin`, `gt`, `lt`, '
     '`gteq`, `lteq`, `null`, `notnull`, `from`, `to`.'),
    ('searchCriteriaSortField',
     'searchCriteria[sortOrders][0][field]', 'string',
     'Field to sort the result set by.'),
    ('searchCriteriaSortDirection',
     'searchCriteria[sortOrders][0][direction]', 'string',
     'Sort direction: `ASC` or `DESC`.'),
    ('searchCriteriaPageSize',
     'searchCriteria[pageSize]', 'integer',
     'Number of items per page.'),
    ('searchCriteriaCurrentPage',
     'searchCriteria[currentPage]', 'integer',
     '1-based index of the page to return.'),
]

# ---------------------------------------------------------------------------
# Error model (references/doc-structure.md — REST Error Model)
# ---------------------------------------------------------------------------
THROW_STATUS = {
    'NoSuchEntityException': '404',
    'AuthorizationException': '403',
    'InputException': '400',
    'LocalizedException': '400',
}
STATUS_DESCRIPTION = {
    '400': 'Bad request — the payload or query failed validation.',
    '401': 'Unauthenticated — the bearer token is missing, expired or invalid.',
    '403': 'Forbidden — the token does not carry the required ACL resource.',
    '404': 'Not found — no entity matches the supplied identifier.',
}
ERROR_SCHEMA = {
    'type': 'object',
    'description': 'Magento REST error envelope. `parameters` and `trace` are present '
                   'only in developer mode.',
    'properties': {
        'message': {'type': 'string'},
        'parameters': {'type': 'object'},
        'trace': {'type': 'string'},
    },
}

SECURITY_SCHEMES = {
    'adminBearer': {'type': 'http', 'scheme': 'bearer', 'bearerFormat': 'JWT',
                    'description': 'Admin or integration access token.'},
    'customerBearer': {'type': 'http', 'scheme': 'bearer', 'bearerFormat': 'JWT',
                       'description': 'Customer access token (`self` scope).'},
    'integrationBearer': {'type': 'http', 'scheme': 'bearer', 'bearerFormat': 'JWT',
                          'description': 'Integration access token.'},
}

def security_for(route):
    kind = route.get('auth_kind')
    if kind == 'anonymous':
        return None
    if kind == 'self':
        return [{'customerBearer': []}]
    return [{'adminBearer': []}, {'integrationBearer': []}]

def short_name(fqcn):
    return (fqcn or '').lstrip('\\').split('\\')[-1]

def operation_id(route):
    raw = '%s_%s' % (short_name(route.get('service_class', '')) or 'service',
                     route.get('service_method', '') or 'call')
    chunks = [c for c in re.split(r'[^A-Za-z0-9]+', raw) if c]
    if not chunks:
        return 'operation'
    head = chunks[0][0].lower() + chunks[0][1:]
    return head + ''.join(c[0].upper() + c[1:] for c in chunks[1:])

def error_responses(route):
    statuses = set()
    if route.get('auth_kind') != 'anonymous':
        statuses.add('401')
    if route.get('acl_resources'):
        statuses.add('403')
    for fqcn in route.get('throws') or []:
        status = THROW_STATUS.get(short_name(fqcn))
        if status:
            statuses.add(status)
    out = {}
    for status in sorted(statuses):
        out[status] = {
            'description': STATUS_DESCRIPTION[status],
            'content': {'application/json': {
                'schema': {'$ref': '#/components/schemas/Error'}}},
        }
    return out

# ---------------------------------------------------------------------------
# OpenAPI document
# ---------------------------------------------------------------------------
def build_openapi():
    info = {'title': '%s_%s REST API' % (VENDOR, MODULE)}
    # Never invent a version: omit the key when composer.json does not carry one.
    if COMPOSER.get('version'):
        info['version'] = str(COMPOSER['version'])
    info['description'] = (COMPOSER.get('description')
                           or 'REST endpoints declared by %s_%s in etc/webapi.xml.'
                           % (VENDOR, MODULE))

    servers = [{
        'url': 'https://{host}/rest/{store}',
        'variables': {
            'host': {'default': 'magento.test',
                     'description': 'Magento base host.'},
            'store': {'default': 'all',
                      'description': 'Store-view code, or `all` for the default scope.'},
        },
    }]

    paths = {}
    uses_search_criteria = False
    for route in routes:
        template = route.get('url_template') or route.get('url') or ''
        method = (route.get('method') or 'GET').lower()
        item = paths.setdefault(template, {})
        op = {'operationId': operation_id(route)}
        op['summary'] = '%s %s' % ((route.get('method') or 'GET').upper(), template)
        op['description'] = 'Service: `%s::%s` (declared in `%s`).' % (
            route.get('service_class', ''), route.get('service_method', ''),
            route.get('file', 'etc/webapi.xml'))

        parameters = []
        for pp in route.get('path_params') or []:
            parameters.append({
                'name': pp['name'], 'in': 'path', 'required': True,
                'schema': {'type': pp.get('type') or 'string'},
            })
        if route.get('is_search_criteria'):
            uses_search_criteria = True
            for cname, _n, _t, _d in SEARCH_CRITERIA_PARAMS:
                parameters.append({'$ref': '#/components/parameters/%s' % cname})
        if parameters:
            op['parameters'] = parameters

        req_schema = route.get('request_schema')
        req_param = route.get('request_param')
        if req_schema and req_param and method in ('post', 'put', 'patch'):
            # ServiceInputProcessor keys the body by the parameter name.
            body_schema = {'type': 'object',
                           'properties': {req_param: hoist(req_schema)}}
            media = {'schema': body_schema}
            if route.get('request_shape') is not None:
                media['example'] = {req_param: route['request_shape']}
            op['requestBody'] = {'required': True,
                                 'content': {'application/json': media}}

        ok = {'description': 'Success.'}
        res_schema = route.get('response_schema')
        if res_schema:
            media = {'schema': hoist(res_schema)}
            if route.get('response_shape') is not None:
                media['example'] = route['response_shape']
            ok['content'] = {'application/json': media}
        responses = {'200': ok}
        responses.update(error_responses(route))
        op['responses'] = responses

        security = security_for(route)
        if security is None:
            op['security'] = []   # explicit: this route takes no credentials
        else:
            op['security'] = security
        if route.get('acl_resources'):
            op['x-magento-acl'] = list(route['acl_resources'])
        item[method] = op

    components = {}
    schemas = dict(COMPONENT_SCHEMAS)
    schemas['Error'] = ERROR_SCHEMA
    components['schemas'] = {name: schemas[name] for name in sorted(schemas)}
    if uses_search_criteria:
        components['parameters'] = {
            cname: {'name': pname, 'in': 'query', 'required': False,
                    'description': desc, 'schema': {'type': ptype}}
            for cname, pname, ptype, desc in SEARCH_CRITERIA_PARAMS
        }
    components['securitySchemes'] = SECURITY_SCHEMES

    ordered_paths = {k: paths[k] for k in sorted(paths)}
    return {
        'OPENAPI_INFO': yaml_block('info', info),
        'OPENAPI_SERVERS': yaml_block('servers', servers),
        'OPENAPI_PATHS': yaml_block('paths', ordered_paths),
        'OPENAPI_COMPONENTS': yaml_block('components', components),
    }

# ---------------------------------------------------------------------------
# JetBrains HTTP Client
# ---------------------------------------------------------------------------
def http_url(route):
    template = route.get('url_template') or route.get('url') or ''
    path = re.sub(r'\{(\w+)\}', r'{{\1}}', template)
    return '{{baseUrl}}/{{store}}%s' % path

def build_http():
    blocks = []
    for route in routes:
        method = (route.get('method') or 'GET').upper()
        lines = ['### %s %s' % (method, route.get('url_template') or route.get('url') or '')]
        lines.append('# Service: %s::%s' % (route.get('service_class', ''),
                                            route.get('service_method', '')))
        if route.get('acl_resources'):
            lines.append('# ACL: %s' % ', '.join(route['acl_resources']))
        else:
            lines.append('# Auth scope: %s' % (route.get('auth_kind') or 'acl'))
        lines.append('%s %s' % (method, http_url(route)))
        lines.append('Accept: application/json')
        body = None
        if (route.get('request_shape') is not None and route.get('request_param')
                and method in ('POST', 'PUT', 'PATCH')):
            body = jdump({route['request_param']: route['request_shape']})
            lines.append('Content-Type: application/json')
        if route.get('auth_kind') != 'anonymous':
            lines.append('Authorization: Bearer {{authToken}}')
        if body is not None:
            lines.append('')
            lines.append(body)
        blocks.append('\n'.join(lines))
    return '\n\n'.join(blocks)

def env_variables():
    """Ordered variable list shared by the .http env and the Postman environment.
    `secret` marks a value that must ship empty."""
    variables = [('baseUrl', 'https://magento.test/rest', False),
                 ('store', 'all', False)]
    if any(r.get('auth_kind') != 'anonymous' for r in routes):
        variables.append(('authToken', '', True))
    seen = {name for name, _v, _s in variables}
    for route in routes:
        for pp in route.get('path_params') or []:
            if pp['name'] not in seen:
                seen.add(pp['name'])
                variables.append((pp['name'], '', False))
    return variables

def build_http_env():
    return jdump({'dev': {name: value for name, value, _secret in env_variables()}})

# ---------------------------------------------------------------------------
# Postman
# ---------------------------------------------------------------------------
# Deterministic collection id: regenerating must produce a clean `git diff`.
POSTMAN_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL,
                               'urn:magento2-tools:magento2-docs-generate:postman')

def build_postman_info():
    return {
        '_postman_id': str(uuid.uuid5(POSTMAN_NAMESPACE, '%s_%s' % (VENDOR, MODULE))),
        'name': '%s_%s REST API' % (VENDOR, MODULE),
        'description': 'Generated by magento2-docs-generate from etc/webapi.xml.',
        'schema': 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
    }

def postman_request(route):
    method = (route.get('method') or 'GET').upper()
    template = route.get('url_template') or route.get('url') or ''
    segments = [re.sub(r'\{(\w+)\}', r'{{\1}}', s)
                for s in template.strip('/').split('/') if s]
    path = ['{{store}}'] + segments
    raw = '{{baseUrl}}/' + '/'.join(path)
    url = {'raw': raw, 'host': ['{{baseUrl}}'], 'path': path}
    if route.get('is_search_criteria'):
        url['query'] = [{'key': pname, 'value': '', 'disabled': True, 'description': desc}
                        for _c, pname, _t, desc in SEARCH_CRITERIA_PARAMS]
    request = {'method': method, 'header': [{'key': 'Accept',
                                             'value': 'application/json'}]}
    if route.get('auth_kind') == 'anonymous':
        request['auth'] = {'type': 'noauth'}
    if (route.get('request_shape') is not None and route.get('request_param')
            and method in ('POST', 'PUT', 'PATCH')):
        request['header'].append({'key': 'Content-Type', 'value': 'application/json'})
        request['body'] = {
            'mode': 'raw',
            'raw': jdump({route['request_param']: route['request_shape']}),
            'options': {'raw': {'language': 'json'}},
        }
    request['url'] = url
    request['description'] = 'Service: %s::%s' % (route.get('service_class', ''),
                                                  route.get('service_method', ''))
    return {'name': '%s %s' % (method, template), 'request': request}

def build_postman_items():
    """Folder per first path segment after the slug; routes with nothing after the
    slug stay at collection root. Root items first, then folders sorted by name."""
    root = []
    folders = {}
    slug_segments = SLUG_SEGMENTS
    for route in routes:
        template = route.get('url_template') or route.get('url') or ''
        segments = [s for s in template.strip('/').split('/') if s]
        if segments and VERSION_SEG_RE.match(segments[0]):
            segments = segments[1:]
        # Drop the slug prefix (it may span more than one segment).
        idx = 0
        while (idx < len(segments) and idx < len(slug_segments)
               and segments[idx] == slug_segments[idx]):
            idx += 1
        rest = segments[idx:]
        item = postman_request(route)
        if rest and not rest[0].startswith('{'):
            folders.setdefault(rest[0], []).append(item)
        else:
            root.append(item)
    items = list(root)
    for name in sorted(folders):
        items.append({'name': name, 'item': folders[name]})
    return items

def build_postman_env_values():
    return [{'key': name, 'value': value,
             'type': 'secret' if secret else 'default', 'enabled': True}
            for name, value, secret in env_variables()]

# ---------------------------------------------------------------------------
# Secret / privacy gate (blocking, per generated file)
# ---------------------------------------------------------------------------
ALLOWED_HOSTS = {'magento.test', 'schema.getpostman.com'}
SECRET_KEY_NAME_RE = re.compile(r'(?i)(token|secret|key|password|credential)')
VAR_REFERENCE_RE = re.compile(r'\{\{\w+\}\}')
FORBIDDEN_SOURCE_RE = re.compile(
    r'(?i)(var/log/|app/etc/env\.php|(^|[/\s"\'])auth\.json|(^|[/\s"\'])\.env\b)')

GATE_PATTERNS = [
    (1, 'credential-literal',
     re.compile(r'(?i)(bearer\s+[A-Za-z0-9._-]{8,}'
                r'|api[_-]?key\s*[:=]\s*\S'
                r'|secret\s*[:=]\s*\S'
                r'|password\s*[:=]\s*\S)')),
    (2, 'jwt-shape', re.compile(r'eyJ[A-Za-z0-9_-]{6,}\.')),
    (3, 'aws-key', re.compile(r'(AKIA|ASIA)[0-9A-Z]{16}'
                              r'|X-Amz-Signature='
                              r'|X-Amz-Credential=')),
    (6, 'personal-identifier',
     re.compile(r'_postman_exported_by|_postman_exported_using'
                r'|[\w.+-]+@[\w-]+\.\w+')),
    (9, 'non-static-source', FORBIDDEN_SOURCE_RE),
]

# `Bearer {{authToken}}` / `"token"` placeholders are the artifacts' own variable
# syntax, not a credential. Everything else must survive assertion 1 unaided.
GATE_EXEMPT_RE = re.compile(r'Bearer \{\{\w+\}\}')

def gate(text, payload):
    """Return a list of violations for one generated file."""
    violations = []
    probe = GATE_EXEMPT_RE.sub('Bearer <placeholder>', text)
    for number, label, pattern in GATE_PATTERNS:
        m = pattern.search(probe)
        if m:
            violations.append({'assertion': number, 'rule': label,
                               'match': m.group(0)[:120]})
    # 4 — every secret-named variable ships empty.
    for key, value in _iter_pairs(payload):
        text_value = str(value).strip()
        if not text_value or VAR_REFERENCE_RE.fullmatch(text_value):
            continue
        if SECRET_KEY_NAME_RE.search(str(key)):
            violations.append({'assertion': 4, 'rule': 'non-empty-secret-variable',
                               'match': '%s=%s' % (key, text_value[:60])})
    # 5 — no host outside the {host} template form or the documented default.
    for host in re.findall(r'https?://([A-Za-z0-9.\-]+)', probe):
        if host not in ALLOWED_HOSTS:
            violations.append({'assertion': 5, 'rule': 'concrete-host',
                               'match': host})
    return violations

def _iter_pairs(node):
    """Yield every (name, scalar-value) pair in a nested JSON-ish structure.
    Postman's {"key": k, "value": v} form collapses to (k, v) — the literal
    members `key` and `value` are the envelope, not a variable named "key"."""
    if isinstance(node, dict):
        envelope = (isinstance(node.get('key'), str) and 'value' in node
                    and not isinstance(node['value'], (dict, list)))
        if envelope:
            yield node['key'], node['value']
        for key, value in node.items():
            if envelope and key in ('key', 'value'):
                continue
            if isinstance(value, (dict, list)):
                yield from _iter_pairs(value)
            else:
                yield key, value
    elif isinstance(node, list):
        for item in node:
            yield from _iter_pairs(item)

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
def render(template_name, tokens):
    fpath = os.path.join(template_dir, template_name)
    with open(fpath, encoding='utf-8') as fh:
        text = fh.read()
    for token, value in tokens.items():
        text = text.replace('{%s}' % token, value)
    left = re.findall(r'\{([A-Z][A-Z0-9_]*)\}', text)
    if left:
        raise SystemExit('emit-api-artifacts: unsubstituted token(s) %s in %s'
                         % (sorted(set(left)), template_name))
    if template_name.endswith('.json'):
        # Re-serialize so a substituted block lands at the right indentation. Doubles
        # as the "parses as JSON" check the Phase 4 gate requires.
        try:
            return jdump(json.loads(text))
        except ValueError as exc:
            raise SystemExit('emit-api-artifacts: %s did not render valid JSON: %s'
                             % (template_name, exc))
    return text

report = {'module': '%s_%s' % (VENDOR, MODULE), 'slug': SLUG,
          'output_dir': output_dir, 'formats': sorted(formats),
          'written': [], 'skipped': [], 'blocked': [],
          'warnings': warnings, 'followups': []}

if not routes:
    report['skipped'].append({'reason': 'no REST routes in etc/webapi.xml'})
    out = json.dumps(report, indent=2)
    if report_file:
        with open(report_file, 'w', encoding='utf-8') as fh:
            fh.write(out + '\n')
    print(out)
    raise SystemExit(0)

# Directory rule: refuse to emit anywhere that would create {module}/api.
abs_out = os.path.normpath(os.path.abspath(output_dir))
abs_module = os.path.normpath(os.path.abspath(module_path))
if os.path.dirname(abs_out) == abs_module and os.path.basename(abs_out).lower() == 'api':
    raise SystemExit('emit-api-artifacts: refusing to write {module}/api — it collides '
                     'with {module}/Api on case-insensitive filesystems. Use '
                     '{module}/docs/api.')
lowercase_api = os.path.join(abs_module, 'api')
api_dir_existed = os.path.isdir(lowercase_api)

pending = []   # (relative path, text, payload-or-None)

if 'openapi' in formats:
    pending.append(('openapi.yaml', render('openapi.yaml', build_openapi()), None))

if 'http-client' in formats:
    http_env = build_http_env()
    pending.append(('%s.http' % SLUG,
                    render('http-client.http', {
                        'Vendor': VENDOR, 'Module': MODULE, 'API_SLUG': SLUG,
                        'HTTP_CLIENT_REQUESTS': build_http()}),
                    None))
    pending.append(('http-client.env.json',
                    render('http-client.env.json', {'HTTP_CLIENT_ENV': http_env}),
                    json.loads(http_env)))

if 'postman' in formats:
    collection = render('postman-collection.json', {
        'POSTMAN_INFO': jdump(build_postman_info()),
        'POSTMAN_ITEMS': jdump(build_postman_items())})
    environment = render('postman-environment.json', {
        'Vendor': VENDOR, 'Module': MODULE,
        'POSTMAN_ENV_VALUES': jdump(build_postman_env_values())})
    pending.append((os.path.join('postman', '%s.postman_collection.json' % SLUG),
                    collection, json.loads(collection)))
    pending.append((os.path.join('postman', '%s.postman_environment.json' % SLUG),
                    environment, json.loads(environment)))

# Never generate the private env file (assertion 7): it is the JetBrains token store
# and it sits next to the .http file, outside .idea/, so a stock .gitignore misses it.
PRIVATE_ENV = 'http-client.private.env.json'
pending = [(rel, text, payload) for rel, text, payload in pending
           if os.path.basename(rel) != PRIVATE_ENV]

blocked_any = False
to_write = []
for rel_path, text, payload in pending:
    violations = gate(text, payload if payload is not None else {})
    if violations:
        blocked_any = True
        for v in violations:
            v['file'] = rel_path.replace(os.sep, '/')
            report['blocked'].append(v)
    else:
        to_write.append((rel_path, text))

for rel_path, text in to_write:
    target = os.path.join(output_dir, rel_path)
    parent = os.path.dirname(target)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(target, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text if text.endswith('\n') else text + '\n')
    report['written'].append(os.path.relpath(target, module_path).replace(os.sep, '/'))

# Post-write assertions 7 + 8.
private_path = os.path.join(output_dir, PRIVATE_ENV)
if any(os.path.basename(p) == PRIVATE_ENV for p in report['written']):
    raise SystemExit('emit-api-artifacts: internal error — %s must never be written'
                     % PRIVATE_ENV)
if not api_dir_existed and os.path.isdir(lowercase_api):
    raise SystemExit('emit-api-artifacts: internal error — created {module}/api')

if 'http-client' in formats and any(p.endswith('.http') for p in report['written']):
    report['followups'].append(
        'Add `/docs/api/%s` to the module .gitignore before committing — the '
        'JetBrains HTTP Client stores your bearer token there and it sits next to '
        'the .http file, not inside .idea/.' % PRIVATE_ENV)
if warnings:
    report['followups'].append(
        'Fix the %d bare `array`/`mixed` annotation(s) listed under warnings: while '
        'any one of them is present, GET /rest/<store>/schema returns HTTP 500 for '
        'EVERY service on the installation.' % len(warnings))

out = json.dumps(report, indent=2)
if report_file:
    parent = os.path.dirname(report_file)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(report_file, 'w', encoding='utf-8') as fh:
        fh.write(out + '\n')
print(out)
raise SystemExit(2 if blocked_any else 0)
PY
rc=$?
exit "$rc"
