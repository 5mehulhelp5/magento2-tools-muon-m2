# Smoke Run — Iteration {N}

Feature: {FeatureName}
Date: {YYYY-MM-DDTHH:MM:SSZ}
Iteration: {N} / 5
Base URL: {url}
Triggered by: feature Phase 6B

---

## Probe Summary (S1)

| Probe | Result |
|-------|--------|
| Base URL | {url} |
| Admin URL | {/admin or resolved fragment} |
| Admin user | {user} (password from {CLAUDE.md / env / prompt}) |
| HTTP client | curl {version} / php-curl / unavailable |
| Browser | playwright {ver} / puppeteer {ver} / unavailable (a bare Chrome binary is not a backend) |
| Browser policy | {auto / curl-only} — {reason: prompt directive / flag / CLAUDE.md / env / unavailable} |
| Coverage tier | {full / **degraded** — curl tier, S4/S5 and JS flows not covered} |
| jq | {ver} / unavailable |
| `exception.log` size at baseline | {bytes} bytes |
| Logs baselined | {N} files under `var/log/` |
| Report files at baseline | {N} under `var/report/` |
| Signal scan | full / **degraded** ({reason} — only `exception.log` was checked) |
| Production guard | {passed / overridden via CLAUDE.md} |

Skipped suites: {S2, S7, … with one-sentence reason each, or "none"}.

---

## S2 — REST API Scenarios

Total scenarios: {N} | Passed: {N} | Failed: {N}

| # | Endpoint | Scenario | Expect | Actual | Severity | Finding ID |
|---|----------|----------|--------|--------|----------|------------|
| 1 | POST /V1/{vendor}/xyz | Happy path | 200 | 200 | — | — |
| 2 | POST /V1/{vendor}/xyz | Missing auth | 401 | 200 | Critical | F1 |
| 3 | GET /V1/{vendor}/xyz/:id | Not found | 404 | 500 | Critical | F2 |

Raw request/response: `smoke/raw/S2/*.txt`.
Full scenarios: `smoke/scenarios.md`.

---

## S3 — Admin Login

- Outcome: {passed / failed}
- Response status: {200}
- Console errors: {none / list}
- Screenshot: `smoke/screenshots/run-{N}/admin-login.png`

---

## S4 — Stores → Configuration

| Section | Loaded | Field changed | Save status | Reverted | Severity |
|---------|--------|---------------|-------------|----------|----------|
| `{vendor}/general` | yes | `enabled` | 200 | yes | — |
| `{vendor}/api` | yes | `timeout_ms` | 500 | n/a | High |

---

## S5 — Admin Grids

| Grid | Rendered | Filter applied | Rows after filter | Cleared | Console errors | Severity |
|------|----------|----------------|-------------------|---------|----------------|----------|
| Customers | yes | name=Smith | 3 | yes | none | — |
| Catalog Products | yes | sku contains TEST | 12 | yes | none | — |
| Sales Orders | yes | status=processing | 5 | yes | 1 (KO bind) | Medium |
| {New grid added by feature} | yes | … | … | … | none | — |

---

## S6 — New / Changed Routes

| Route | Type | Render | Primary CTA clicked | Result | Console errors | Severity |
|-------|------|--------|---------------------|--------|----------------|----------|
| `/admin/{vendor}/xyz/index` | admin | 200 | New entity | 200 | none | — |
| `/{vendor}/xyz/account` | frontend | 200 | Update | 500 | 1 (uncaught) | Critical |

---

## S7 — Customer Storefront Flows

| Step | Result | Console errors | Severity |
|------|--------|----------------|----------|
| Registration | succeeded — id 1234 | none | — |
| Logout | succeeded | none | — |
| Login | succeeded | none | — |
| My Account → Account Information | rendered | none | — |
| My Account → Address Book | rendered | 1 (warn — ignored) | — |
| My Account → My Orders | rendered | none | — |
| My Account → {new tab added by feature} | failed to load | 1 (error) | High |

Throwaway customer: `smoke+a1b2c3@example.test` — cleaned up in S9.

---

## S8 — Error-Signal Diff

Sources scanned (from `smoke/raw/S8/signals.json`):

| Source | New bytes / files | Levels seen | Rotated / created | Gating |
|--------|-------------------|-------------|--------------------|--------|
| `var/log/exception.log` | {bytes} | {CRITICAL: N} | no | {N} |
| `var/log/system.log` | {bytes} | {ERROR: N, INFO: N} | no | {N} |
| `var/log/{module}.log` | {bytes} | {ERROR: N} | created during run | {N} |
| `var/report/**` | {N new, N refreshed} | n/a | n/a | {N} |

Signals (aggregated by signature — `x{N}` is the occurrence count):

| # | Severity | Gating | Category | Source | Attributed | x | First line / report message | Allowlisted |
|---|----------|--------|----------|--------|-----------|---|------------------------------|-------------|
| S8-1 | Critical | yes | log_error | `var/log/system.log` | yes | 4 | `main.CRITICAL: Type Error occurred when creating object: Vendor\Xyz\Plugin\Foo` | no |
| S8-2 | High | yes | report_file | `var/report/ab/cd/…` | no | 1 | `Required parameter 'theme_dir' was not passed` | no |
| S8-3 | Medium | no | log_error | `var/log/cron.log` | no | 6 | `main.ERROR: Cron Job consumers_runner has an error` | no |

Exit code: {0 none / 1 gating / 4 recorded-only / 5 degraded}.
Artefacts: `smoke/raw/S8/signals.json`, `exception-diff.log`, `logs/{name}.diff`,
`reports/{name}.json`.
Coverage caveats (`degraded[]`): {list, or "none"}.

---

## S9 — Triage

### New findings this iteration

| ID | Severity | Category | Source suite | Summary | Fix delegate |
|----|----------|----------|--------------|---------|--------------|
| F1 | Critical | rest_contract | S2 | POST /V1/xyz returns 200 for unauthenticated request | fix |
| F2 | Critical | rest_contract | S2 | GET 404 case throws 500 stack trace | fix + debug |
| F3 | High | frontend | S7 | New My Account tab fails to load | frontend |
| F4 | Critical | php_exception | S8 | Controller class not found | debug → fix |

### Recurring findings (same ID as prior iteration)

{None this iteration / list with iteration of first sighting}

### Outcome

- Critical: {N}   High: {N}   Medium: {N}   Low: {N}
- **Decision:** {PASS — proceed to Phase 7 / FAIL — fix Critical/High and re-enter Phase 6 / HALT — iteration cap reached}
- Next action: {description}

Iteration counter after this run: {N} / 5.
