#!/usr/bin/env bash
# Shared harness for the docs-generate API-artifact tests.
#
# Each test works on a THROWAWAY COPY of tests/fixtures/docs-generate/Acme/Sample so a
# test may mutate the fixture (seed a secret, drop a file) without touching the tracked
# one and without leaking state into the next test.
#
# Usage:
#   . tests/lib/docs-api-artifacts.sh
#   docs_api_workdir            # -> $DA_WORK, $DA_MODULE  (caller traps cleanup)
#   docs_api_generate [formats] # -> $DA_API_DIR, $DA_REPORT, $DA_RC

DA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DA_FIXTURE="$DA_ROOT/tests/fixtures/docs-generate/Acme/Sample"
DA_EXTRACT="$DA_ROOT/skills/docs/scripts/extract-surface.sh"
DA_EMIT="$DA_ROOT/skills/docs/scripts/emit-api-artifacts.sh"

docs_api_workdir() {
    DA_WORK="$(mktemp -d)"
    mkdir -p "$DA_WORK/Acme"
    cp -r "$DA_FIXTURE" "$DA_WORK/Acme/Sample"
    DA_MODULE="$DA_WORK/Acme/Sample"
    DA_SURFACE="$DA_WORK/surface.json"
    DA_REPORT="$DA_WORK/report.json"
    DA_API_DIR="$DA_MODULE/docs/api"
}

docs_api_generate() {
    local formats="${1:-openapi,http-client,postman}"
    MODULE_PATH="$DA_MODULE" SURFACE_FILE="$DA_SURFACE" bash "$DA_EXTRACT" >/dev/null || {
        echo "FAIL: extractor errored"; return 1; }
    DA_RC=0
    MODULE_PATH="$DA_MODULE" SURFACE_FILE="$DA_SURFACE" FORMATS="$formats" \
        REPORT_FILE="$DA_REPORT" bash "$DA_EMIT" >/dev/null 2>"$DA_WORK/emit.err" || DA_RC=$?
    return 0
}
