# Smoke Findings — {FeatureName}

Append-only across all Phase 6 iterations. Each finding gets a stable ID at first sight; the same
ID is reused on subsequent iterations if the finding recurs. Resolved findings keep their row but
gain a `Resolved in` column entry.

---

## Finding ID format

`F{N}` — assigned sequentially starting at F1 within a single feature run. IDs do not reset
between iterations; they reset only between feature runs.

---

## Severity counts (latest iteration)

| Severity | Open | Resolved | Allowlisted |
|----------|------|----------|-------------|
| Critical | {N} | {N} | {N} |
| High     | {N} | {N} | {N} |
| Medium   | {N} | {N} | {N} |
| Low      | {N} | {N} | {N} |

---

## Findings

| ID | Severity | Category | First seen (iter) | Last seen (iter) | Source suite | Summary | Fix delegate | Resolved in (iter) | Notes |
|----|----------|----------|--------------------|-------------------|--------------|---------|--------------|---------------------|-------|
| F1 | Critical | rest_contract | 1 | 2 | S2 | POST /V1/{vendor}/xyz returns 200 for unauthenticated request | magento2-bug-fix | 3 | ACL declaration missing in webapi.xml |
| F2 | Critical | php_exception | 1 | 1 | S8 | `Class Vendor\Xyz\Foo not found` in exception.log | magento2-debug → magento2-bug-fix | 2 | Class name typo in di.xml |
| F3 | High | frontend | 1 | 3 | S7 | New My Account tab "Vehicles" fails to load — uncaught reference error in vehicle.js | magento2-frontend-create | — | Still open; cap reached |
| F4 | Medium | performance | 1 | 1 | S6 | New admin grid renders in 2.3s (target 2.0s) | magento2-performance-audit | n/a | Recorded; not loop-gating |
| F5 | Critical | log_error | 1 | 1 | S8 | `Type Error occurred when creating object: Vendor\Xyz\Plugin\Foo` in system.log ×4 — never reached exception.log | magento2-debug → magento2-bug-fix | 2 | Constructor arg missing from di.xml; signature `main.CRITICAL: Type Error occurred when creating object: Vendor\Xyz\Plugin\Foo, Too few arguments` |
| F6 | High | report_file | 1 | 1 | S8 | New `var/report/api/N` after POST /V1/... — PHP fatal, no log entry at all | magento2-debug → magento2-bug-fix | — | Decoded copy in `smoke/raw/S8/reports/` |

---

## Iteration history

| Iteration | Date/time | New findings | Resolved findings | Decision |
|-----------|-----------|---------------|--------------------|----------|
| 1 | 2026-05-28T10:14Z | F1, F2, F3, F4 | — | FAIL — re-enter Phase 6 |
| 2 | 2026-05-28T10:42Z | — | F2 | FAIL — F1 + F3 open, re-enter Phase 6 |
| 3 | 2026-05-28T11:05Z | — | F1 | FAIL — F3 open, re-enter Phase 6 |
| 4 | 2026-05-28T11:31Z | — | — | FAIL — F3 still open, re-enter Phase 6 |
| 5 | 2026-05-28T11:58Z | — | — | HALT — iteration cap reached |

---

## At halt (if reached)

- Unresolved Critical: {list of IDs or "none"}
- Unresolved High: {list of IDs or "none"}
- User prompt issued: see `run-{N}.md` "Halt" section.
- User decision: {retry / accept-known-issues F3 / abort / pending}

---

## Categories

`rest_contract`, `php_exception`, `log_error`, `log_warning`, `log_unparsed`, `log_missing`,
`log_unreadable`, `report_file`, `frontend`, `controller`, `layout`, `grid`, `config_save`,
`customer_flow`, `performance`, `security`, `schema`, `smoke_coverage`, `other`.

The S8 categories map 1:1 to `signals.json`: `php_exception` (exception.log group),
`log_error`/`log_warning` (another `var/log/*.log` at ERROR+/WARNING), `report_file` (a new or
refreshed `var/report/**` file), `log_unparsed`/`log_missing`/`log_unreadable` (scan integrity),
and `smoke_coverage` (S8 exited 5 — only `exception.log` was checked).

Findings sourced from S8 carry the `signature` from `signals.json` in the Notes column. That
signature — not the line text — is what matches a finding across iterations, since timestamps
and ids differ on every recurrence.
