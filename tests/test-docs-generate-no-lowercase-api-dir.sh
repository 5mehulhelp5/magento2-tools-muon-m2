#!/usr/bin/env bash
# Every module with a REST surface already has {module}/Api/. On a case-insensitive
# filesystem — macOS by default, Windows, any unpacked .zip — {module}/api/ IS
# {module}/Api/, so creating one corrupts the PSR-4 tree and breaks autoloading for the
# whole module. Nesting under {module}/docs/api/ avoids the collision; this test pins it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

. tests/lib/docs-api-artifacts.sh
docs_api_workdir
trap 'rm -rf "$DA_WORK"' EXIT

BEFORE="$(cd "$DA_MODULE" && find Api -type f | sort | xargs md5sum 2>/dev/null || true)"

docs_api_generate || exit 1
FAIL=0
[ "$DA_RC" -eq 0 ] || { echo "FAIL: emitter exited $DA_RC"; cat "$DA_WORK/emit.err"; FAIL=1; }

# 1. No lowercase api/ directory anywhere in the module root.
while IFS= read -r d; do
    echo "FAIL: a lowercase api directory was created: $d"
    FAIL=1
done < <(cd "$DA_MODULE" && find . -maxdepth 1 -type d -name api)

# 2. The output landed under docs/api instead.
[ -f "$DA_API_DIR/openapi.yaml" ] || { echo "FAIL: docs/api/openapi.yaml missing"; FAIL=1; }

# 3. Api/ is untouched, byte for byte.
AFTER="$(cd "$DA_MODULE" && find Api -type f | sort | xargs md5sum 2>/dev/null || true)"
if [ "$BEFORE" != "$AFTER" ]; then
    echo "FAIL: {module}/Api was modified by the run"
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") || true
    FAIL=1
fi

# 4. Asked to write there explicitly, the emitter must refuse rather than comply.
rc=0
MODULE_PATH="$DA_MODULE" SURFACE_FILE="$DA_SURFACE" OUTPUT_DIR="$DA_MODULE/api" \
    bash "$DA_EMIT" >"$DA_WORK/refuse.out" 2>&1 || rc=$?
if [ "$rc" -ne 1 ]; then
    echo "FAIL: OUTPUT_DIR={module}/api must be refused with exit 1, got $rc"
    FAIL=1
fi
if ! grep -q 'case-insensitive' "$DA_WORK/refuse.out"; then
    echo "FAIL: the refusal must explain the case-insensitive collision"
    cat "$DA_WORK/refuse.out"
    FAIL=1
fi
if [ -d "$DA_MODULE/api" ]; then
    echo "FAIL: the refused run still created {module}/api"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "PASS: no lowercase api/ directory"
exit 0
