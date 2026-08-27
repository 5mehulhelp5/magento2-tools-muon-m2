# Execution Modes (Shared)

How a findings/RCA skill decides whether its analysis runs as parallel **subagents** or
**inline** in the main conversation. Consumed by `audit`, `review`, `security`,
`perf-audit`, `a11y-audit`, `marketplace`, and `fix`. The mode changes only *where* the
work runs — the same references, checklists, and findings schema apply either way.

## The two modes

| Mode | What happens | When it wins |
|------|--------------|--------------|
| `agents` | Read-only subagents are dispatched in parallel — `reviewer` (one per findings dimension), `explorer` (comprehension / RCA path-tracing) — and the skill owns synthesis: dedup, severity normalization, conflict tie-breaking. | Large modules, multi-dimension audits, security-sensitive targets. Faster wall-clock; main context stays small. |
| `inline` | The skill executes the same analysis itself, sequentially, in the main conversation. | Small targets, step-by-step steering, token-frugal runs, environments where subagents are unavailable. |

## Selection, in precedence order

1. **Per run** — `--agents` or `--inline` on the invocation, or plain language
   ("in one flow", "without subagents", "use parallel agents", "delegate").
2. **Per project** — `m2.executionMode` (`"agents"` | `"inline"`) in the project's
   `.claude/settings.json`. Read it directly from the file; absence means no preference.
3. **Per-skill default** — `audit` defaults to `agents` (its whole point is the
   fan-out); every other consumer defaults to `inline`.

State the chosen mode (and what chose it: flag, setting, or default) in the run header
of the report.

## Invariants — identical in both modes

- **Approval gates always run in the main conversation.** A gate (RCA approval, deploy
  confirmation, fix authorization) is never delegated to a subagent, in either mode.
- **Same canon.** Both modes read the same reference packs and emit the same
  findings-schema JSON/SARIF via the shared emitters. Scripted scanners
  (`build-findings.sh`) are deterministic and run as scripts in both modes.
- **Read-only agents.** `reviewer` and `explorer` never modify code; only the main
  conversation writes.

## Documented divergence

An inline run can pause and ask the user a clarifying question mid-analysis. A subagent
cannot: in `agents` mode, ambiguities are resolved conservatively and listed in the
report under **Open questions** instead. This difference is inherent, not a bug — pick
`inline` when the target is ambiguous enough that mid-run steering matters.
