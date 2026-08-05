# Runtime Test Tooling

Which tool exercises which surface when a skill tests a **running** Magento instance. Shared by
`magento2-feature-implement` (Phase 6B smoke), `magento2-deploy` (post-deploy smoke),
`magento2-bug-fix` (reproduction), and `magento2-accessibility-audit` (runtime pa11y pass).
Those skills point here; they do not restate these rules.

Related: `magento2-context/references/tool-probe.md` (where `tools.curl` and
`tools.headless_browser` come from), `magento2-context/references/severity.md` (the severity
scale the degraded-coverage finding uses).

---

## Rule 1 — REST, GraphQL, and every Web-API surface use `curl`

Always `curl`. Never a browser, and never a browser-automation MCP server.

`curl` gives exact control of method, headers, auth token, and body, and reports the literal
status code. A browser interposes a JS and cookie layer that masks the contract under test: a
`401` you needed to observe becomes a redirect to a login page, and a malformed body becomes a
rendered error screen.

Fallback when `curl` is missing (`ctx.tools.curl == null`): PHP cURL via
`{ctx.runner} php -r "..."`. Never a browser.

**This rule has no override.** No flag, directive, or environment makes a browser the right tool
for an HTTP API.

## Rule 2 — Admin and storefront smoke use a headless browser, and only headless

Drive them through the owning skill's own script (`magento2-feature-implement` uses
`${CLAUDE_PLUGIN_ROOT}/skills/magento2-feature-implement/scripts/smoke-browser.mjs`, which walks
Playwright → Puppeteer and stops there). Always headless.

**A bare Chrome or Chromium binary is not a browser backend.** `google-chrome`, `chromium`, and
`chromium-browser` cannot drive these suites — the raw-CDP rung that used one was deleted for
fake-passing — so `ctx.tools.headless_browser` reports Playwright, Puppeteer, or `null`, and
nothing else. A machine with Chrome installed but no Playwright/Puppeteer is a `curl-only`
machine.

- Never launch a headed or visible browser. These runs are unattended.
- Never assume an interactive browser-automation MCP server is attached. Skills must work in CI
  and in sessions with no MCP servers at all.

## Rule 3 — A browser is never assumed to exist

`ctx.tools.headless_browser == null` is a normal, expected state — not an error, not a defect,
not a reason to halt. Every skill that would drive a browser has a `curl` tier (Rule 5) and uses
it instead.

## Rule 4 — Resolving `browser_policy`

`browser_policy` is resolved **per run**, highest priority first:

| # | Source | Value |
|---|--------|-------|
| 1 | Natural-language directive in the user's prompt | `curl-only` |
| 2 | `--no-browser` / `--curl-only` flag | `curl-only` |
| 3 | `CLAUDE.md` line `Smoke browser: off` | `curl-only` |
| 4 | env `MAGENTO2_SMOKE_NO_BROWSER=1` | `curl-only` |
| 5 | probe — `ctx.tools.headless_browser == null` | `curl-only` (reason: unavailable) |
| 6 | otherwise | `auto` |

Only two values exist, because Rule 1 is absolute — there is no "force browser" mode to express.

- `auto` — headless browser for admin and storefront, `curl` for REST.
- `curl-only` — `curl` for everything; browser suites are replaced by the tier in Rule 5.

### Prompt directives that select `curl-only`

Match these, case-insensitively: `do not use browser`, `don't use a browser`, `no browser`,
`without a browser`, `browserless`, `use curl`, `curl only`, `curl-only`.

**Do not** flip the policy because the word "browser" merely appears in the request. "Add a
browser-support banner to the storefront" is a feature description, not a tooling instruction.
The trigger is an instruction about *how to test*, not a noun in *what to build*. When a phrase
is genuinely ambiguous, ask — and fold the question into the skill's existing single question
batch rather than interrupting mid-run.

Record the resolved policy, and which row of the table decided it, in the run report. A wrong
flip must be visible to the reader.

### `browser_policy` is never cached

It is **not** a field of the `magento2-context` JSON. That cache is keyed on `composer.lock`, so
a prompt-scoped directive persisted there would be silently reused on an unrelated later run.
Only the probes (`ctx.tools.curl`, `ctx.tools.headless_browser`) are cached; the policy is
derived per run by the consuming skill.

## Rule 5 — The degraded `curl` tier

Used whenever `browser_policy == curl-only`. It replaces browser-driven admin and storefront
suites with unauthenticated HTTP reachability checks.

| Checked | Assertion |
|---------|-----------|
| `GET /{adminPath}` | 302 to login, or 200 with a login form. Fail on 5xx or 404. |
| each feature-owned **admin** route | 302 to login — proves the route is registered, not 404/500 |
| each feature-owned **frontend** route | non-5xx, plus an optional expected-marker grep of the HTML |
| REST / GraphQL scenarios | run **in full**, unchanged — they were always `curl` |
| error-signal diff (`var/log`, `var/report`) | runs **in full**, unchanged |

### Authenticated admin work is not attempted

Magento 2.4 requires both a form key and mandatory 2FA on admin login, so a `curl` "admin login"
would be flaky theatre that fails for environmental reasons and reads as a product defect.
Config walks, admin grids, and customer JS flows are therefore reported as **not covered**
rather than faked.

### The degraded-coverage finding is mandatory

The trigger is **"the curl tier ran"**, not "`browser_policy` was `curl-only`". If the policy
resolved to `auto` but the browser turned out unusable at runtime (the driver exits `78`), the
finding is still mandatory — otherwise a probe that is wrong in the optimistic direction
silently buys back the fake-pass this rule exists to block.

Every such run emits one **Medium** finding, category `coverage`, naming exactly what was
not checked — JS console errors, render assertions, click-through, and any authenticated screen.
Medium does not gate, so the run may still pass; but the finding must appear in the run report
and in the consuming skill's final limitations section.

This mirrors the degraded-scan pattern the error-signal diff already uses (exit code `5`), and it
is the guard against the raw-CDP fallback that was removed from this repo for fake-passing.
