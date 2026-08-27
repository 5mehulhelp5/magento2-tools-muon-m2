#!/usr/bin/env bash
# test-execution-modes.sh — the 2.0 execution-mode contract: one canonical reference
# defines mode selection; every audit/RCA-family skill cites it, names its default,
# and the mode flags are exposed on the matching commands. Gates stay in the main
# conversation in both modes.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAIL=0
CANON=skills/context/references/execution-modes.md

[ -f "$CANON" ] || { echo "FAIL: $CANON missing"; exit 1; }
for token in '--agents' '--inline' 'm2.executionMode' 'in precedence order' \
             'Approval gates always run in the main conversation'; do
    grep -qF -- "$token" "$CANON" || { echo "FAIL: canon lacks '$token'"; FAIL=1; }
done
# The two agents the contract dispatches must exist.
for a in reviewer explorer; do
    [ -f "agents/$a.md" ] || { echo "FAIL: agents/$a.md missing"; FAIL=1; }
done

# Every consumer cites the canon and names its default.
declare -A DEFAULT=(
    [audit]=agents [review]=inline [security]=inline [perf-audit]=inline
    [a11y-audit]=inline [marketplace]=inline [fix]=inline
)
for skill in "${!DEFAULT[@]}"; do
    md="skills/$skill/SKILL.md"
    grep -q 'context/references/execution-modes.md' "$md" \
        || { echo "FAIL: $md does not cite the execution-modes canon"; FAIL=1; }
    case "${DEFAULT[$skill]}" in
        agents) grep -qE 'Default: \*\*agents\*\*' "$md" \
            || { echo "FAIL: $md must state default agents"; FAIL=1; } ;;
        inline) grep -qiE 'default is \*\*inline\*\*|Default: \*\*inline\*\*' "$md" \
            || { echo "FAIL: $md must state default inline"; FAIL=1; } ;;
    esac
done

# The RCA gate stays in the main conversation in either mode.
grep -q 'approval gate below always runs in the main' skills/fix/SKILL.md \
    || { echo "FAIL: fix must pin the RCA gate to the main conversation"; FAIL=1; }

# Commands expose the flags.
for cmd in audit review security perf bugfix; do
    grep -q -- '--agents|--inline' "commands/$cmd.md" \
        || { echo "FAIL: commands/$cmd.md argument-hint lacks --agents|--inline"; FAIL=1; }
done

exit "$FAIL"
