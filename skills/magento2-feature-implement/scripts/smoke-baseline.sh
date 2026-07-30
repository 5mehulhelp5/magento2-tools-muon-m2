#!/usr/bin/env bash
# smoke-baseline.sh — capture the S1 error-signal baseline for a smoke run.
#
# Usage:
#   smoke-baseline.sh <output-baseline-file> [<magento-root>]
#
# Captures three signal sources, because Magento records failures in all three and an
# exception.log-only baseline reports PASS while two of them are on fire:
#   1. var/log/exception.log            — byte offset + rotation hash (legacy keys, unchanged)
#   2. every var/log/*.log (+ .log.1)   — byte offset + rotation hash per file
#   3. var/report/** (recursive)        — path + mtime per existing report file
#
# Magento root resolution order:
#   1. $2 (explicit)          2. $MAGENTO_ROOT
#   3. src/  (if src/app/etc/env.php exists)
#   4. .     (if app/etc/env.php exists)
#   5. first */app/etc/env.php found via `find` capped at depth 4
#   6. first */var/log/exception.log found via `find` capped at depth 4
#
# Output file format (key=value, plus two list sections):
#   file=<absolute path to exception.log>     # legacy — unchanged, still parsed by old callers
#   size_bytes=<size>
#   sha256_of_last_4096=<hex>
#   captured_at=<ISO8601 UTC>
#   magento_root=<absolute path>
#   log_root=<absolute path>
#   report_root=<absolute path>
#   captured_epoch=<float seconds>
#   degraded=<reason>                         # only when a section could not be captured
#   [logs]
#   log=<abs path>|<size_bytes>|<sha256_of_last_4096>
#   [reports]
#   report=<abs path>|<mtime epoch float>
#
# Exit codes:
#   0 — baseline captured (files may not exist yet — that is recorded, not an error)
#   2 — could not locate a Magento root
#
# When python3 is unavailable the [logs]/[reports] sections are omitted and `degraded=` is set;
# smoke-tail-since.sh then falls back to the exception.log-only diff and exits 5 so the caller
# records the reduced coverage as a finding instead of reading it as a clean run.

set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "usage: $0 <output-baseline-file> [<magento-root>]" >&2
  exit 64
fi

OUT="$1"
ROOT_ARG="${2:-${MAGENTO_ROOT:-}}"

abspath() {
  readlink -f "$1" 2>/dev/null || python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$1"
}

resolve_root() {
  if [[ -n "${ROOT_ARG}" ]]; then
    echo "${ROOT_ARG%/}"
    return 0
  fi
  if [[ -f "src/app/etc/env.php" ]]; then
    echo "src"
    return 0
  fi
  if [[ -f "app/etc/env.php" ]]; then
    echo "."
    return 0
  fi
  local found
  found="$(find . -maxdepth 4 -type f -path '*/app/etc/env.php' 2>/dev/null | head -n1 || true)"
  if [[ -n "${found}" ]]; then
    found="${found%/app/etc/env.php}"
    echo "${found#./}"
    return 0
  fi
  # Last resort: a var/log/exception.log without a readable env.php (partial checkout).
  found="$(find . -maxdepth 4 -type f -path '*/var/log/exception.log' 2>/dev/null | head -n1 || true)"
  if [[ -n "${found}" ]]; then
    found="${found%/var/log/exception.log}"
    echo "${found#./}"
    return 0
  fi
  return 1
}

ROOT="$(resolve_root || true)"
if [[ -z "${ROOT}" ]]; then
  echo "no Magento root found (looked for app/etc/env.php and var/log/exception.log)" >&2
  exit 2
fi

LOG_PATH="${ROOT}/var/log/exception.log"
ABS_ROOT="$(abspath "${ROOT}")"
ABS_PATH="$(abspath "${LOG_PATH}")"
ABS_LOG_ROOT="${ABS_ROOT}/var/log"
ABS_REPORT_ROOT="${ABS_ROOT}/var/report"

# --- legacy keys: exception.log byte offset + rotation hash (behaviour unchanged) ---
if [[ -f "${LOG_PATH}" ]]; then
  SIZE="$(stat -c '%s' "${LOG_PATH}" 2>/dev/null || stat -f '%z' "${LOG_PATH}")"
  if [[ "${SIZE}" -gt 0 ]]; then
    if [[ "${SIZE}" -le 4096 ]]; then
      SHA="$(sha256sum "${LOG_PATH}" | awk '{print $1}')"
    else
      SHA="$(tail -c 4096 "${LOG_PATH}" | sha256sum | awk '{print $1}')"
    fi
  else
    SHA="0"
  fi
else
  SIZE=0
  SHA="0"
fi

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
EPOCH="$(date -u +%s)"

mkdir -p "$(dirname "${OUT}")"
cat > "${OUT}" <<EOF
file=${ABS_PATH}
size_bytes=${SIZE}
sha256_of_last_4096=${SHA}
captured_at=${NOW}
magento_root=${ABS_ROOT}
log_root=${ABS_LOG_ROOT}
report_root=${ABS_REPORT_ROOT}
captured_epoch=${EPOCH}
EOF

# --- manifest sections: every log file + every existing report file ---
if command -v python3 >/dev/null 2>&1; then
  python3 - "${OUT}" "${ABS_LOG_ROOT}" "${ABS_REPORT_ROOT}" <<'PY'
import hashlib
import os
import sys

out_path, log_root, report_root = sys.argv[1], sys.argv[2], sys.argv[3]

# Cap the report manifest so a var/report with a runaway file count cannot blow up the
# baseline. Truncation is recorded, never silent: the diff step falls back to mtime-only
# detection for the unlisted remainder.
REPORT_MANIFEST_CAP = 5000


def tail_sha(path: str, size: int) -> str:
    if size <= 0:
        return '0'
    with open(path, 'rb') as fh:
        if size > 4096:
            fh.seek(size - 4096)
        return hashlib.sha256(fh.read(4096)).hexdigest()


logs = []
if os.path.isdir(log_root):
    for name in sorted(os.listdir(log_root)):
        if not (name.endswith('.log') or name.endswith('.log.1')):
            continue
        path = os.path.join(log_root, name)
        if not os.path.isfile(path):
            continue
        try:
            size = os.path.getsize(path)
            logs.append('log=%s|%d|%s' % (path, size, tail_sha(path, size)))
        except OSError as exc:
            logs.append('log_unreadable=%s|%s' % (path, exc.__class__.__name__))

reports = []
truncated = 0
if os.path.isdir(report_root):
    for dirpath, _dirnames, filenames in os.walk(report_root):
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if len(reports) >= REPORT_MANIFEST_CAP:
                truncated += 1
                continue
            try:
                reports.append('report=%s|%.6f' % (path, os.path.getmtime(path)))
            except OSError:
                truncated += 1
    reports.sort()

with open(out_path, 'a', encoding='utf-8') as fh:
    if truncated:
        fh.write('reports_truncated=%d\n' % truncated)
    fh.write('[logs]\n')
    for line in logs:
        fh.write(line + '\n')
    fh.write('[reports]\n')
    for line in reports:
        fh.write(line + '\n')

print('  logs=%d  reports=%d%s' % (
    len(logs), len(reports), '  (truncated %d)' % truncated if truncated else ''))
PY
else
  echo "degraded=python3-missing" >> "${OUT}"
  echo "WARNING: python3 not available — only exception.log was baselined." >&2
  echo "         var/report/** and other var/log/*.log files will NOT be checked at S8." >&2
fi

echo "baseline written: ${OUT}"
echo "  magento_root=${ABS_ROOT}"
echo "  file=${ABS_PATH}"
echo "  size_bytes=${SIZE}"
echo "  captured_at=${NOW}"
