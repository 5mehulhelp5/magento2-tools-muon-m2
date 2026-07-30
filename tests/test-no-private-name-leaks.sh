#!/usr/bin/env bash
# test-no-private-name-leaks.sh — this repository is PUBLIC. Nothing in it may carry a client's
# module names, a private store's hostnames, an internal report title, or a local filesystem
# path. Those leak in easily and invisibly, because the plugin is developed by using it on real
# client stores: a rule, a CHANGELOG entry or a doc example gets written straight from whatever
# was on screen.
#
# The guard is deliberately client-agnostic — it names no client, only the SANCTIONED
# placeholders. Anything outside that set is a leak by construction, so a client encountered for
# the first time next year is caught with no edit to this file.
#
# Layers:
#   1. Magento module identifiers (`Vendor_Module`) whose vendor is not a sanctioned placeholder.
#   2. PHP namespace roots, with the same rule — but the repo habitually abbreviates core
#      namespaces (`Logger\Handler\System`, `ObjectManager\Factory\...`), and the root of an
#      abbreviation is shape-identical to a vendor name. So the structural vocabulary is
#      SELF-CALIBRATED: any segment that appears INSIDE a known-framework namespace anywhere in
#      the repo is structural, and everything else is a candidate vendor. A client's name never
#      appears inside `Magento\…`, so it cannot whitelist itself.
#   3. Composer package names (`vendor/module-...`) with the same rule.
#   4. Local absolute paths (/home/..., /Users/...) — always a developer machine.
#   5. `*.localhost` and similar private store hostnames.
#   6. Concrete `.docs/bug-fixes/<slug>` citations — internal report titles. `{slug}` and the
#      dated illustrative examples used by the docs are fine.
#
# Residual risk it CANNOT catch: an all-lowercase identifier derived from a client name — a queue
# topic like `<client>.sms`, a config path, a CSS class. Those are shape-identical to legitimate
# examples. When writing about a real store, describe the mechanism and leave the identifier out.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Vendors the repo is allowed to name: documentation placeholders, Magento itself, and third
# parties whose PUBLIC extensions the skills legitimately integrate with.
#
# Adding a name here is a deliberate act. Before doing so, be certain it is a public,
# documentation-appropriate vendor and not the store you happened to be working in.
SANCTIONED_VENDORS='Acme|Vendor|MyVendor|My|Magento|Zend|Laminas|Symfony|Psr|Mage|Swissup|Adobe|Example|Foo|Bar|Baz|ModuleA|ModuleB|Rector|Magewirephp'

# Paths that legitimately contain fixture/example data are still checked: a fixture is exactly
# where a real name gets pasted by accident. Only the build/VCS dirs are skipped.
mapfile -t FILES < <(git ls-files -- '*.md' '*.sh' '*.json' '*.php' '*.xml' '*.phtml' '*.mjs' \
    '*.js' '*.less' '*.csv' '*.yml' '*.yaml' 2>/dev/null)
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "FAIL: no tracked files found to scan"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not on PATH"
    exit 77
fi

SANCTIONED_VENDORS="$SANCTIONED_VENDORS" python3 - "${FILES[@]}" <<'PY'
import os
import re
import sys

sanctioned = set(os.environ['SANCTIONED_VENDORS'].split('|'))
paths = sys.argv[1:]

# A Magento module id / namespace root: PascalCase both sides. The second character must be
# lowercase so SHOUT_CASE env vars (TARGET_PATH, SKILL_VERSION) are not module ids.
# The VENDOR half must have a lowercase second character, which is what keeps SHOUT_CASE env
# vars (TARGET_PATH, SKILL_VERSION) out. The MODULE half must not: real module names carry
# consecutive capitals (SMSNotification, B2BExport, APIBridge), and requiring a lowercase there
# is exactly how the first version of this guard missed a leaked client module.
MODULE_ID = re.compile(r'\b([A-Z][a-z][A-Za-z0-9]*)_([A-Z][A-Za-z0-9]*[a-z][A-Za-z0-9]*)\b')
NAMESPACE = re.compile(r'(?<![\w\\])([A-Z][a-z][A-Za-z0-9]*)\\\\?([A-Z][a-z][A-Za-z0-9]*)\\')
COMPOSER = re.compile(r'\b([a-z][a-z0-9]{2,})/(module-[a-z0-9-]+)\b(?!\.md)')
COMPOSER_NOT_VENDOR = {'references', 'templates', 'scripts', 'docs', 'skills', 'tests',
                       'php', 'src', 'app', 'view', 'etc', 'code', 'vendor'}
LOCAL_PATH = re.compile(r'(?:/home/[a-z][\w.-]*|/Users/[a-z][\w.-]*)/')
PRIVATE_HOST = re.compile(r'\b[\w-]+\.localhost\b')
BUGFIX_SLUG = re.compile(r'\.docs/bug-fixes/(?!\{slug\})([a-z0-9][a-z0-9-]{6,})')

# Composer vendor tokens are lowercase; map the sanctioned set into that space too. `muon-m2` is
# this project's own GitHub org and appears in URLs — allowed as an org slug, but NOT as a
# composer vendor shipping client modules, which is why it is not in SANCTIONED_VENDORS.
sanctioned_lower = {v.lower() for v in sanctioned} | {'magento', 'laminas', 'psr', 'symfony'}

# The dated example the bug-fix templates use to illustrate the commit trailer format.
ALLOWED_SLUGS = {'2026-05-24-s3-upload-swallow', 'checkout-500-giftwrap'}

# Pass 1 — learn the structural vocabulary. Every segment that appears inside a known-framework
# namespace is a Magento/PHP structural word, not a vendor.
FRAMEWORK_ROOTS = ('Magento', 'Laminas', 'Symfony', 'Psr', 'Zend')
STRUCTURAL = set()
FRAMEWORK_NS = re.compile(r'\b(?:%s)((?:\\\\?[A-Z][A-Za-z0-9]*)+)' % '|'.join(FRAMEWORK_ROOTS))
for path in paths:
    if not os.path.isfile(path):
        continue
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    except OSError:
        continue
    for m in FRAMEWORK_NS.finditer(text):
        for seg in re.split(r'\\+', m.group(1)):
            if seg:
                STRUCTURAL.add(seg)

problems = []
for path in paths:
    if not os.path.isfile(path):
        continue
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            lines = fh.readlines()
    except OSError:
        continue
    self_scan = path.endswith('test-no-private-name-leaks.sh')
    for n, line in enumerate(lines, start=1):
        if self_scan:
            break  # this file names the sanctioned set; scanning it would match its own patterns
        for m in MODULE_ID.finditer(line):
            if m.group(1) not in sanctioned:
                problems.append((path, n, 'module id', m.group(0)))
        for m in NAMESPACE.finditer(line):
            if m.group(1) not in sanctioned and m.group(1) not in STRUCTURAL:
                problems.append((path, n, 'namespace', m.group(1) + '\\' + m.group(2)))
        for m in COMPOSER.finditer(line):
            if m.group(1) in COMPOSER_NOT_VENDOR:
                continue
            if m.group(1) not in sanctioned_lower:
                problems.append((path, n, 'composer package', m.group(0)))
        for m in LOCAL_PATH.finditer(line):
            problems.append((path, n, 'local path', m.group(0)))
        for m in PRIVATE_HOST.finditer(line):
            problems.append((path, n, 'private host', m.group(0)))
        for m in BUGFIX_SLUG.finditer(line):
            if m.group(1) not in ALLOWED_SLUGS:
                problems.append((path, n, 'internal report title', m.group(1)))

if problems:
    print('FAIL: private names leaked into this PUBLIC repository.')
    print('Replace them with a sanctioned placeholder (%s), or describe the thing by its class'
          % ', '.join(sorted(sanctioned)))
    print('instead of naming it. Only add to SANCTIONED_VENDORS for a genuinely public vendor.')
    print()
    seen = set()
    for path, n, kind, text in problems:
        key = (path, kind, text)
        if key in seen:
            continue
        seen.add(key)
        print('  %s:%d  %s: %s' % (path, n, kind, text))
    print()
    print('  %d occurrence(s), %d distinct' % (len(problems), len(seen)))
    sys.exit(1)

print('no private-name leaks: %d tracked files scanned, %d structural namespace '
      'segments learned' % (len(paths), len(STRUCTURAL)))
PY
