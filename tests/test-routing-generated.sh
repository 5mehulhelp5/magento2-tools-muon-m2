#!/usr/bin/env bash
# test-routing-generated.sh — the README command table is generated from commands/*.md
# and must be fresh; the editorial skill tables must reference only existing
# skills/agents and cover every skill. All enforced by gen-routing.sh --check.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not on PATH"; exit 77; }

bash skills/context/scripts/gen-routing.sh --check
