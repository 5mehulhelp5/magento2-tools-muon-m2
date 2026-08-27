#!/usr/bin/env bash
# smoke-tail-since.sh — S8: diff every error signal against the S1 baseline.
#
# Usage:
#   smoke-tail-since.sh <baseline-file> <output-diff-file> [options]
#
# Options:
#   --json=<path>        machine-readable summary (default: <output-dir>/signals.json)
#   --namespace=<list>   comma-separated Vendor_Module / Vendor\Module owned by the feature.
#                        Drives attribution: an ERROR+ entry naming one of these is the
#                        feature's problem (Critical, gates the loop); one that names none is
#                        background noise (Medium, recorded only) unless it is CRITICAL+.
#   --surfaces=<list>    comma-separated surfaces the feature declares (cron,queue). Makes
#                        ERROR+ in cron/consumer logs gating instead of merely recorded.
#   --allowlist=<path>   file of Python `re` patterns (one per line, `#` comments allowed) — a
#                        group whose first line matches is demoted to Medium and marked
#                        allowlisted. Python `re` is close to PCRE but not identical: `\K`,
#                        recursion and possessive quantifiers are unsupported and an invalid
#                        pattern is reported in signals.json `degraded[]`, never skipped.
#
# Signals, all three diffed against the baseline:
#   1. var/log/exception.log   — byte range [baseline_size .. EOF], rotation-aware (unchanged)
#   2. every other var/log/*.log — same byte-range diff, then level-gated: only ERROR+ counts,
#      because a busy cron.log carries six figures of INFO and "any new byte" is unusable
#   3. var/report/**           — any file that is new, or whose mtime moved (Magento names a
#      report after a hash of its content, so a recurring exception rewrites the same path)
#
# Outputs:
#   <output-diff-file>              raw exception.log diff (unchanged legacy artefact)
#   <output-dir>/logs/<name>.diff   raw diff per other log file that grew
#   <output-dir>/reports/<name>     decoded copy of each new/refreshed report file
#   <output-dir>/signals.json       summary + findings (or --json path)
#
# Exit codes:
#   0 — no signals
#   1 — at least one GATING signal (Critical/High): the iteration fails
#   2 — baseline file missing or malformed
#   3 — live log path could not be located
#   4 — only non-gating signals (Medium): recorded, iteration may still pass
#   5 — scan degraded (python3 unavailable, or baseline captured without manifest sections):
#       the exception.log diff is still written, but sources 2 and 3 were NOT checked. Treat as
#       a Medium finding in its own right — do not read it as a clean run.
#
# `set -e` is on: a failed stat/tail/read must abort loudly rather than fall through to a
# "no signals" verdict on empty artefacts. It is disabled only around the python classifier,
# whose exit code IS the result and is propagated deliberately.

set -euo pipefail

if [[ "${1:-}" == "" || "${2:-}" == "" ]]; then
  echo "usage: $0 <baseline-file> <output-diff-file> [--json=<path>] [--namespace=<list>] [--surfaces=<list>] [--allowlist=<path>]" >&2
  exit 64
fi

BASELINE="$1"
OUT="$2"
shift 2

JSON_OUT=""
NAMESPACES=""
SURFACES=""
ALLOWLIST=""
for arg in "$@"; do
  case "${arg}" in
    --json=*)      JSON_OUT="${arg#*=}" ;;
    --namespace=*) NAMESPACES="${arg#*=}" ;;
    --surfaces=*)  SURFACES="${arg#*=}" ;;
    --allowlist=*) ALLOWLIST="${arg#*=}" ;;
    *) echo "unknown option: ${arg}" >&2; exit 64 ;;
  esac
done

if [[ ! -f "${BASELINE}" ]]; then
  echo "baseline file not found: ${BASELINE}" >&2
  exit 2
fi

BASE_FILE=""
BASE_SIZE=""
BASE_SHA=""
while IFS='=' read -r key val; do
  case "${key}" in
    file) BASE_FILE="${val}" ;;
    size_bytes) BASE_SIZE="${val}" ;;
    sha256_of_last_4096) BASE_SHA="${val}" ;;
  esac
done < "${BASELINE}"

if [[ -z "${BASE_FILE}" || -z "${BASE_SIZE}" ]]; then
  echo "baseline file malformed: ${BASELINE}" >&2
  exit 2
fi

OUT_DIR="$(dirname "${OUT}")"
mkdir -p "${OUT_DIR}"
: > "${OUT}"
[[ -z "${JSON_OUT}" ]] && JSON_OUT="${OUT_DIR}/signals.json"

# ---------------------------------------------------------------------------
# Source 1 — exception.log byte diff. Unchanged from the single-signal version.
# ---------------------------------------------------------------------------
EXCEPTION_MISSING=0
if [[ ! -f "${BASE_FILE}" ]]; then
  echo "MISSING: ${BASE_FILE} disappeared after baseline (size_bytes=${BASE_SIZE})" >> "${OUT}"
  EXCEPTION_MISSING=1
else
  LIVE_SIZE="$(stat -c '%s' "${BASE_FILE}" 2>/dev/null || stat -f '%z' "${BASE_FILE}")"

  rotation_check() {
    # returns 0 if rotation hash still matches (no rotation), 1 if it does not
    local at="${BASE_SIZE}"
    if [[ "${at}" -le 4096 ]]; then
      local end=$(( at ))
      if [[ "${end}" -eq 0 ]]; then return 0; fi
      local sha
      sha="$(head -c "${end}" "${BASE_FILE}" | sha256sum | awk '{print $1}')"
      [[ "${sha}" == "${BASE_SHA}" ]]
    else
      local start=$(( at - 4096 ))
      local sha
      sha="$(dd if="${BASE_FILE}" bs=1 skip="${start}" count=4096 2>/dev/null | sha256sum | awk '{print $1}')"
      [[ "${sha}" == "${BASE_SHA}" ]]
    fi
  }

  if [[ "${LIVE_SIZE}" -ge "${BASE_SIZE}" ]] && rotation_check; then
    if [[ "${LIVE_SIZE}" -gt "${BASE_SIZE}" ]]; then
      tail -c +"$(( BASE_SIZE + 1 ))" "${BASE_FILE}" > "${OUT}"
    fi
  else
    echo "# ROTATION DETECTED: live size ${LIVE_SIZE} < baseline ${BASE_SIZE} or hash mismatch" >> "${OUT}"
    cat "${BASE_FILE}" >> "${OUT}"
    ROTATED="${BASE_FILE}.1"
    if [[ -f "${ROTATED}" ]]; then
      ROT_SIZE="$(stat -c '%s' "${ROTATED}" 2>/dev/null || stat -f '%z' "${ROTATED}")"
      if [[ "${ROT_SIZE}" -gt "${BASE_SIZE}" ]]; then
        echo "# ALSO INCLUDING POST-BASELINE PORTION OF ${ROTATED}" >> "${OUT}"
        tail -c +"$(( BASE_SIZE + 1 ))" "${ROTATED}" >> "${OUT}"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Sources 2 + 3 — other log files and var/report. Needs python3 and a v2 baseline.
# ---------------------------------------------------------------------------
degrade() {
  echo "WARNING: $1" >&2
  echo "         Sources 2 (other var/log/*.log) and 3 (var/report/**) were NOT checked." >&2
  echo "         Record a Medium finding for reduced smoke coverage." >&2
  exit 5
}

command -v python3 >/dev/null 2>&1 || degrade "python3 not available."
grep -q '^\[logs\]' "${BASELINE}" || degrade "baseline has no [logs] section (captured by an older smoke-baseline.sh)."

set +e
python3 - "${BASELINE}" "${OUT}" "${JSON_OUT}" "${NAMESPACES}" "${SURFACES}" "${ALLOWLIST}" "${EXCEPTION_MISSING}" <<'PY'
import json
import os
import re
import sys
import time

baseline_path, exc_diff_path, json_path = sys.argv[1], sys.argv[2], sys.argv[3]
namespaces_arg, surfaces_arg, allowlist_path = sys.argv[4], sys.argv[5], sys.argv[6]
exception_missing = sys.argv[7] == '1'

out_dir = os.path.dirname(os.path.abspath(exc_diff_path))

LEVEL_RANK = {
    'DEBUG': 1, 'INFO': 2, 'NOTICE': 3, 'WARNING': 4,
    'ERROR': 5, 'CRITICAL': 6, 'ALERT': 7, 'EMERGENCY': 8,
}
ERROR_RANK = LEVEL_RANK['ERROR']
CRITICAL_RANK = LEVEL_RANK['CRITICAL']

# Magento's default Monolog line: "[ts] channel.LEVEL: message context extra".
HEADER_RE = re.compile(
    r'^\[(?P<ts>[^\]]+)\]\s+(?P<channel>[\w.\-]+)\.(?P<level>%s):\s?(?P<msg>.*)$'
    % '|'.join(LEVEL_RANK)
)

FINDINGS_CAP = 200
REPORT_LIST_CAP = 200


# --- baseline ---------------------------------------------------------------
keys = {}
base_logs = {}
base_reports = {}
section = None
with open(baseline_path, encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        line = raw.rstrip('\n')
        if line in ('[logs]', '[reports]'):
            section = line
            continue
        if section == '[logs]' and line.startswith('log='):
            path, _, rest = line[4:].partition('|')
            size, _, sha = rest.partition('|')
            try:
                base_logs[path] = (int(size), sha)
            except ValueError:
                base_logs[path] = (0, sha)
        elif section == '[reports]' and line.startswith('report='):
            path, _, mtime = line[7:].partition('|')
            # Integer microseconds, truncated on both sides — see the note in
            # smoke-baseline.sh. A float here would be a pre-release baseline; parse it at the
            # same resolution rather than mixing precisions.
            try:
                base_reports[path] = (int(float(mtime) * 1_000_000) if '.' in mtime
                                      else int(mtime))
            except ValueError:
                base_reports[path] = 0
        elif '=' in line:
            k, _, v = line.partition('=')
            keys[k] = v

log_root = keys.get('log_root', '')
report_root = keys.get('report_root', '')
exception_path = keys.get('file', '')
try:
    captured_epoch = float(keys.get('captured_epoch', '0'))
except ValueError:
    captured_epoch = 0.0
reports_truncated_at_baseline = int(keys.get('reports_truncated', '0') or 0)
# Precise instant the baseline walked var/report, in the same integer-microsecond resolution as
# the manifest entries. Used only for files the capped manifest never listed. Falls back to the
# whole-second captured_epoch, which `date +%s` truncates — hence the +1s guard there.
try:
    reports_scanned_at_us = int(keys['reports_scanned_at_us'])
except (KeyError, ValueError):
    reports_scanned_at_us = int((captured_epoch + 1) * 1_000_000)

namespaces = [n.strip() for n in namespaces_arg.split(',') if n.strip()]
surfaces = {s.strip().lower() for s in surfaces_arg.split(',') if s.strip()}

# Vendor_Module, Vendor\Module and Vendor/Module all appear in log text and traces.
ns_tokens = []
for ns in namespaces:
    base = ns.replace('\\', '_').replace('/', '_')
    parts = base.split('_')
    ns_tokens.extend([base, '\\'.join(parts), '/'.join(parts)])
ns_tokens = [t for t in dict.fromkeys(ns_tokens) if t]

allow_patterns = []
allow_errors = []
if allowlist_path and os.path.isfile(allowlist_path):
    with open(allowlist_path, encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            pat = raw.strip()
            if not pat or pat.startswith('#'):
                continue
            try:
                allow_patterns.append(re.compile(pat))
            except re.error as exc:
                allow_errors.append('%s (%s)' % (pat, exc))


def attributed(text):
    return any(tok in text for tok in ns_tokens)


def allowlisted(text):
    return any(p.search(text) for p in allow_patterns)


# --- log policy ------------------------------------------------------------
def policy_for(basename):
    """exception  — every group gates (unchanged strict gate)
       record_only— debug.log duplicates other streams; ERROR+ recorded, never gates
       surface    — cron/consumer logs: gate only when the feature declares that surface
       standard   — system.log and module channels: ERROR+ gates per attribution"""
    name = basename[:-2] if basename.endswith('.1') else basename
    if name == 'exception.log':
        return 'exception'
    if name == 'debug.log':
        return 'record_only'
    if name == 'cron.log' or name.startswith('magento.cron.') \
            or 'consumer' in name or 'queue' in name:
        return 'surface'
    return 'standard'


def group_lines(text):
    """Split a diff into Magento log groups. A header line starts a group; anything else
    (stack-trace continuation) belongs to the group above it. Text before the first header is
    a group that straddled the baseline offset — reported as unparsed, never dropped."""
    groups = []
    current = None
    for line in text.splitlines():
        if line.startswith('# ROTATION DETECTED') or line.startswith('# ALSO INCLUDING') \
                or line.startswith('MISSING: '):
            continue
        m = HEADER_RE.match(line)
        if m:
            current = {'level': m.group('level'), 'ts': m.group('ts'),
                       'channel': m.group('channel'), 'first': line, 'lines': [line]}
            groups.append(current)
        elif current is not None:
            current['lines'].append(line)
        elif line.strip():
            current = {'level': None, 'ts': None, 'channel': None,
                       'first': line, 'lines': [line]}
            groups.append(current)
    return groups


findings = []
findings_truncated = 0
_by_signature = {}


def signature(line):
    """Collapse volatile parts so N repeats of one fault become one finding with a count.
    Same normalisation idiom as debug/scripts/log-triage.sh."""
    s = re.sub(r'^\[[^\]]+\]\s*', '', line)
    s = re.sub(r'[0-9a-f]{8,}', 'HEX', s)
    s = re.sub(r'\d{2,}', 'N', s)
    s = re.sub(r'/\S+', '/PATH', s)
    s = re.sub(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', 'EMAIL', s)
    return s[:200]


def add_finding(**kw):
    """Findings are aggregated by (category, source, signature). A fault that fires 40 times
    during a run is one finding with occurrences=40, not 40 findings — otherwise a single
    broken plugin fills the report and pushes real distinct faults past the cap."""
    global findings_truncated
    sig = signature(kw.get('summary', ''))
    key = (kw['category'], kw['source'], sig)
    existing = _by_signature.get(key)
    if existing is not None:
        existing['occurrences'] += 1
        existing['last_seen'] = kw.get('ts') or existing['last_seen']
        # Keep the worst severity seen for this signature.
        order = ['Low', 'Medium', 'High', 'Critical']
        if order.index(kw['severity']) > order.index(existing['severity']):
            existing['severity'] = kw['severity']
            existing['gating'] = kw['gating']
        return
    if len(_by_signature) >= FINDINGS_CAP:
        findings_truncated += 1
        return
    kw['id'] = 'S8-%d' % (len(findings) + 1)
    kw['signature'] = sig
    kw['occurrences'] = 1
    kw['first_seen'] = kw.get('ts')
    kw['last_seen'] = kw.get('ts')
    _by_signature[key] = kw
    findings.append(kw)


def classify_group(group, source_path, policy):
    text = '\n'.join(group['lines'])
    level = group['level']
    rank = LEVEL_RANK.get(level, 0)
    is_attributed = attributed(text)

    def emit(severity, gating, category='log_error', **extra):
        add_finding(category=category, severity=severity, gating=gating,
                    source=source_path, level=level, ts=group['ts'],
                    attributed=is_attributed, allowlisted=extra.pop('allowlisted', False),
                    summary=group['first'][:300], **extra)

    if level is None:
        if policy in ('exception', 'standard'):
            emit('Medium', False, category='log_unparsed',
                 note='line(s) with no parseable log level — group straddled the baseline '
                      'offset or a non-Monolog writer appended here')
        return

    if allowlisted(group['first']):
        emit('Medium', False,
             category='php_exception' if policy == 'exception' else 'log_error',
             allowlisted=True)
        return

    if policy == 'exception':
        emit('Critical', True, category='php_exception')
        return

    if rank < ERROR_RANK:
        if rank == LEVEL_RANK['WARNING'] and policy == 'standard':
            emit('Medium', False, category='log_warning')
        return

    if policy == 'record_only':
        emit('Medium', False,
             note='debug.log duplicates other streams — recorded, never gating')
        return

    if policy == 'surface':
        surface_declared = bool(surfaces & {'cron', 'queue', 'consumer', 'message_queue'})
        if is_attributed:
            emit('Critical', True)
        elif surface_declared:
            emit('High', True,
                 note='feature declares a cron/queue surface, so background cron errors '
                      'are in scope')
        else:
            emit('Medium', False,
                 note='cron/consumer log, no cron/queue surface declared')
        return

    # standard
    if is_attributed:
        emit('Critical', True)
    elif rank >= CRITICAL_RANK:
        emit('High', True,
             note='CRITICAL+ in a gated log but not attributable to the feature — allowlist '
                  'it in CLAUDE.md if it is known background noise')
    else:
        emit('Medium', False, note='ERROR not attributable to the feature')


def tail_sha(path, size):
    import hashlib
    if size <= 0:
        return '0'
    with open(path, 'rb') as fh:
        if size > 4096:
            fh.seek(size - 4096)
        return hashlib.sha256(fh.read(4096)).hexdigest()


# --- source 1: classify the exception.log diff bash already extracted ------
log_summaries = []
if exception_missing:
    add_finding(category='log_missing', severity='High', gating=True,
                source=exception_path, level=None, attributed=False, allowlisted=False,
                summary='exception.log disappeared after the baseline was taken')
    log_summaries.append({'path': exception_path, 'policy': 'exception', 'new_bytes': 0,
                          'levels': {}, 'groups': 0, 'unparsed_lines': 0,
                          'created_during_run': False, 'rotated': False, 'missing': True})
else:
    exc_text = ''
    if os.path.isfile(exc_diff_path):
        with open(exc_diff_path, encoding='utf-8', errors='replace') as fh:
            exc_text = fh.read()
    groups = group_lines(exc_text)
    levels = {}
    for g in groups:
        levels[g['level'] or 'UNPARSED'] = levels.get(g['level'] or 'UNPARSED', 0) + 1
        classify_group(g, exception_path, 'exception')
    log_summaries.append({
        'path': exception_path, 'policy': 'exception',
        'new_bytes': len(exc_text.encode('utf-8', 'replace')), 'levels': levels,
        'groups': len(groups),
        'unparsed_lines': sum(len(g['lines']) for g in groups if g['level'] is None),
        'created_during_run': False,
        'rotated': 'ROTATION DETECTED' in exc_text, 'missing': False,
    })

# --- source 2: every other var/log/*.log -----------------------------------
logs_dir_missing = not os.path.isdir(log_root)
live_logs = []
if not logs_dir_missing:
    for name in sorted(os.listdir(log_root)):
        if not (name.endswith('.log') or name.endswith('.log.1')):
            continue
        path = os.path.join(log_root, name)
        if os.path.isfile(path):
            live_logs.append(path)

diff_dir = os.path.join(out_dir, 'logs')
for path in live_logs:
    if os.path.abspath(path) == os.path.abspath(exception_path):
        continue  # handled above
    name = os.path.basename(path)
    policy = policy_for(name)
    try:
        live_size = os.path.getsize(path)
    except OSError as exc:
        add_finding(category='log_unreadable', severity='Medium', gating=False,
                    source=path, level=None, attributed=False, allowlisted=False,
                    summary='could not stat %s (%s)' % (name, exc.__class__.__name__))
        continue

    created = path not in base_logs
    base_size, base_sha = base_logs.get(path, (0, '0'))
    inherited_offset = False
    if created and name.endswith('.log.1'):
        # A `.log.1` that was not in the baseline is not new content — it IS the file we
        # baselined, renamed by a rotation mid-run. Scanning it from byte 0 would re-surface
        # every pre-baseline error in it as a fresh finding. Inherit the parent log's baseline
        # offset, exactly as the exception.log path does for its own `.1`.
        parent = path[:-2]
        if parent in base_logs:
            base_size, base_sha = base_logs[parent]
            created = False
            inherited_offset = True

    rotated = False
    if not created and live_size >= base_size and base_size > 0 and not inherited_offset:
        try:
            if tail_sha(path, base_size) != base_sha:
                rotated = True
        except OSError:
            rotated = True
    elif not created and live_size < base_size:
        rotated = True

    start = 0 if (created or rotated) else base_size
    if live_size <= start:
        continue
    try:
        with open(path, 'rb') as fh:
            fh.seek(start)
            chunk = fh.read()
    except OSError as exc:
        add_finding(category='log_unreadable', severity='Medium', gating=False,
                    source=path, level=None, attributed=False, allowlisted=False,
                    summary='could not read %s (%s)' % (name, exc.__class__.__name__))
        continue

    text = chunk.decode('utf-8', 'replace')
    groups = group_lines(text)
    levels = {}
    for g in groups:
        levels[g['level'] or 'UNPARSED'] = levels.get(g['level'] or 'UNPARSED', 0) + 1
        classify_group(g, path, policy)

    os.makedirs(diff_dir, exist_ok=True)
    with open(os.path.join(diff_dir, name + '.diff'), 'w', encoding='utf-8') as fh:
        if rotated:
            fh.write('# ROTATION DETECTED: re-read from byte 0\n')
        if created:
            fh.write('# CREATED DURING RUN: whole file is new\n')
        if inherited_offset:
            fh.write('# ROTATED INTO PLACE MID-RUN: read from the pre-rotation baseline '
                     'offset %d, not byte 0\n' % start)
        fh.write(text)

    log_summaries.append({
        'path': path, 'policy': policy, 'new_bytes': len(chunk), 'levels': levels,
        'groups': len(groups),
        'unparsed_lines': sum(len(g['lines']) for g in groups if g['level'] is None),
        'created_during_run': created, 'rotated': rotated, 'missing': False,
    })

# a baselined log that vanished mid-run
for path in base_logs:
    if not os.path.isfile(path):
        add_finding(category='log_missing', severity='Medium', gating=False,
                    source=path, level=None, attributed=False, allowlisted=False,
                    summary='log file present at baseline is now gone (rotated away or '
                            'deleted) — entries written during the run may be lost')

# --- source 3: var/report/** ----------------------------------------------
def decode_report(path):
    try:
        with open(path, 'rb') as fh:
            raw = fh.read(65536)
    except OSError as exc:
        return {'format': 'unreadable', 'message': exc.__class__.__name__, 'raw': ''}
    text = raw.decode('utf-8', 'replace').strip()
    try:
        data = json.loads(text)
    except ValueError:
        if re.match(r'^[aOs]:\d+:', text):
            return {'format': 'php-serialized', 'message': text[:400], 'raw': text[:4000]}
        return {'format': 'raw', 'message': text[:400], 'raw': text[:4000]}
    if isinstance(data, dict):
        msg = data.get('0') or data.get(0) or data.get('message') or ''
        return {'format': 'json', 'message': str(msg)[:400],
                'url': data.get('url', ''), 'script_name': data.get('script_name', ''),
                'report_id': data.get('report_id', ''),
                'raw': text[:4000]}
    if isinstance(data, str):
        return {'format': 'json', 'message': data[:400], 'raw': text[:4000]}
    return {'format': 'json', 'message': str(data)[:400], 'raw': text[:4000]}


report_root_missing = not os.path.isdir(report_root)
new_reports, refreshed_reports = [], []
reports_listed = 0
reports_scan_truncated = 0
if not report_root_missing:
    for dirpath, _dirnames, filenames in os.walk(report_root):
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            try:
                mtime_us = os.stat(path).st_mtime_ns // 1000
            except OSError:
                continue
            mtime = mtime_us / 1_000_000
            reports_listed += 1
            if path in base_reports:
                if mtime_us > base_reports[path]:
                    refreshed_reports.append((path, mtime))
            elif reports_truncated_at_baseline and mtime_us <= reports_scanned_at_us:
                # Baseline manifest was capped and this file predates the run.
                continue
            else:
                new_reports.append((path, mtime))

    hits = [(p, m, 'new') for p, m in new_reports] + \
           [(p, m, 'refreshed') for p, m in refreshed_reports]
    hits.sort(key=lambda t: t[1])
    if len(hits) > REPORT_LIST_CAP:
        reports_scan_truncated = len(hits) - REPORT_LIST_CAP
        hits = hits[:REPORT_LIST_CAP]

    copy_dir = os.path.join(out_dir, 'reports')
    for path, mtime, kind in hits:
        decoded = decode_report(path)
        rel = os.path.relpath(path, report_root).replace(os.sep, '_')
        os.makedirs(copy_dir, exist_ok=True)
        with open(os.path.join(copy_dir, rel + '.json'), 'w', encoding='utf-8') as fh:
            json.dump({'path': path, 'kind': kind, 'mtime': mtime, **decoded}, fh, indent=2)

        blob = decoded.get('raw') or decoded.get('message') or ''
        is_api = os.sep + 'api' + os.sep in path
        summary = '%s error report %s: %s' % (
            'API' if is_api else 'HTTP', kind, (decoded.get('message') or '')[:200])
        common = dict(category='report_file', source=path, level=None, ts=time.strftime(
            '%Y-%m-%dT%H:%M:%SZ', time.gmtime(mtime)), summary=summary,
            report_format=decoded['format'])
        if allowlisted(decoded.get('message') or ''):
            add_finding(severity='Medium', gating=False, attributed=attributed(blob),
                        allowlisted=True, **common)
        elif attributed(blob):
            add_finding(severity='Critical', gating=True, attributed=True,
                        allowlisted=False, note='report names the feature namespace', **common)
        else:
            add_finding(severity='High', gating=True, attributed=False, allowlisted=False,
                        note='an uncaught exception or PHP fatal reached the error processor '
                             'during the smoke run; var/report/api/* is written with NO log '
                             'entry at all', **common)

gating = sum(1 for f in findings if f['gating'])
recorded = len(findings) - gating

summary = {
    'schema': 'm2-smoke-signals/1',
    'baseline_captured_at': keys.get('captured_at', ''),
    'scanned_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'magento_root': keys.get('magento_root', ''),
    'namespaces': namespaces,
    'surfaces': sorted(surfaces),
    'degraded': [],
    'sources': {
        'logs': log_summaries,
        'reports': {
            'root': report_root,
            'root_missing': report_root_missing,
            'listed': reports_listed,
            'new': len(new_reports),
            'refreshed': len(refreshed_reports),
            'truncated': reports_scan_truncated,
            'baseline_manifest_truncated': reports_truncated_at_baseline,
        },
    },
    'counts': {'gating': gating, 'recorded': recorded,
               'findings_truncated': findings_truncated},
    'findings': findings,
}
if logs_dir_missing:
    summary['degraded'].append('log_root missing: %s' % log_root)
if report_root_missing:
    summary['degraded'].append('report_root missing: %s (no report has ever been written)'
                               % report_root)
if allow_errors:
    summary['degraded'].append('invalid allowlist pattern(s): %s' % '; '.join(allow_errors))
if findings_truncated:
    summary['degraded'].append('%d finding(s) beyond the %d cap were not listed'
                               % (findings_truncated, FINDINGS_CAP))
if reports_scan_truncated:
    summary['degraded'].append('%d report file(s) beyond the %d cap were not decoded'
                               % (reports_scan_truncated, REPORT_LIST_CAP))

os.makedirs(os.path.dirname(os.path.abspath(json_path)), exist_ok=True)
with open(json_path, 'w', encoding='utf-8') as fh:
    json.dump(summary, fh, indent=2)

print('signals: gating=%d recorded=%d  (logs scanned=%d, reports new=%d refreshed=%d)' % (
    gating, recorded, len(log_summaries), len(new_reports), len(refreshed_reports)))
order = {'Critical': 0, 'High': 1, 'Medium': 2, 'Low': 3}
for f in sorted(findings, key=lambda x: (order.get(x['severity'], 9), -x['occurrences']))[:20]:
    print('  [%s] %-8s %-13s x%-4d %s' % (
        'GATE' if f['gating'] else 'note', f['severity'], f['category'],
        f['occurrences'], f['summary'][:100]))
for d in summary['degraded']:
    print('  ! %s' % d)

sys.exit(1 if gating else (4 if recorded else 0))
PY
rc=$?
set -e
exit "${rc}"
