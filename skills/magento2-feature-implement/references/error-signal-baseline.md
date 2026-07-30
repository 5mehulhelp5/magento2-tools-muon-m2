# Error-Signal Baseline (S1 + S8)

The smoke battery requires that **no new error signal appears from the feature's code** during a
run (acceptance criterion #9). Three sources are baselined at S1 and diffed at S8, because
Magento does not record all failures in one place — and an `exception.log`-only gate reports PASS
while the other two are on fire.

| # | Source | Why it is not optional |
|---|--------|------------------------|
| 1 | `var/log/exception.log` | The historical gate. Byte-offset diff, rotation-aware. |
| 2 | every other `var/log/*.log` | `Logger\Handler\System::write()` routes a record to `exception.log` **only if `$record['context']['exception']` is set**. A string-level critical — e.g. `ObjectManager\Factory\AbstractFactory` logging `Type Error occurred when creating object: Vendor\Module\Plugin\Foo, Too few arguments` — lands in `system.log` and is invisible to source 1. Module channels (`var/log/{vendor}_{module}.log`) are invisible too. |
| 3 | `var/report/**` | `Webapi\ErrorProcessor::apiShutdownFunction()` writes `var/report/api/{id}` on a PHP fatal with **no logger call at all**. `pub/errors/processor.php::saveReport()` writes `var/report/{sha256}` (nested under `var/report/xx/yy/` when `MAGE_ERROR_REPORT_DIR_NESTING_LEVEL` or `pub/errors/local.xml`'s `dir_nesting_level` is set). A report file exists only because an uncaught exception or fatal reached the error processor. |

Verified against Magento 2.4.8: `framework/Logger/Handler/System.php:57-63`,
`framework/Webapi/ErrorProcessor.php:298-326`, `pub/errors/processor.php:520-533,618-657`,
`framework/App/ExceptionHandler.php:233-257`.

---

## Why byte-offset, not line-count

A Magento site under any kind of background load (cron, indexer, queue consumer, deploy hooks)
can write to the logs between S1 and S8 from sources unrelated to the feature being
smoke-tested. The check is still useful — but only if it can distinguish the new feature's lines
from background noise.

Byte-offset wins over line-count for three reasons:

1. **Rotation detection.** If a file rotates between S1 and S8, its size drops and the
   `sha256_of_last_4096` no longer matches; we treat the entire post-rotation file as new and
   report appropriately.
2. **Concurrent writes.** Line-count diffs lose lines written *between* the read and the count.
   Byte-offset locks in a position; everything after it is "new".
3. **Allowlist precision.** The diff is delivered as raw bytes and can be regex-matched in full,
   including multi-line stack traces that line-count would split.

Report files get a different treatment: **path set plus mtime**. Magento names a report after a
hash of its content, so the same exception thrown twice rewrites the *same path* — a path-set
diff alone would miss the recurrence.

---

## Baseline file format

```
file=/abs/src/var/log/exception.log        # legacy keys — still parsed by older callers
size_bytes=12834
sha256_of_last_4096=ef9c4d2b...
captured_at=2026-05-28T10:14:22Z
magento_root=/abs/src
log_root=/abs/src/var/log
report_root=/abs/src/var/report
captured_epoch=1780000000
reports_scanned_at_us=1780000000123456
[logs]
log=/abs/src/var/log/exception.log|12834|ef9c4d2b...
log=/abs/src/var/log/system.log|31646|aa11bb22...
[reports]
report=/abs/src/var/report/ab/cd/aabb…|1780000000123456
```

Report mtimes are **integer microseconds, truncated** — not a formatted float. A rounded float
loses to its own precision: `'%.6f'` on a real nanosecond mtime can round *down*, leaving the
stored value below the true mtime, so a file nobody touched compares as "refreshed" and fires a
spurious gating finding. Truncating both sides to the same integer resolution makes an unchanged
file compare exactly equal. `reports_scanned_at_us` is taken *before* the walk and is used only
for files the capped manifest never listed.

The `sha256_of_last_4096` hashes the last 4 KiB of the file at baseline time (or the whole file
if shorter). It is the rotation-detection hash: if at diff time the file's bytes ending at
`size_bytes` no longer hash to that value, the file rotated.

The four legacy keys are kept verbatim so a run started on an older script version still parses.
`smoke-baseline.sh` takes an optional second argument — the Magento root — otherwise it resolves
`src/`, then `.`, then the first `*/app/etc/env.php`, then the first
`*/var/log/exception.log`, each capped at depth 4.

---

## Diff algorithm (S8)

```text
Source 1 — exception.log
1. Read baseline. Stat the live file.
2. live size >= baseline size AND rotation hash matches → diff = live bytes [baseline_size .. EOF]
3. live size <  baseline size OR hash mismatch → rotation: diff = whole live file, plus the
   post-baseline portion of exception.log.1 when present.
4. live file gone → "MISSING" marker (High, gating).
5. Save to smoke/raw/S8/exception-diff.log — the artefact path is unchanged.

Source 2 — every other var/log/*.log (+ .log.1)
6. File absent from the baseline manifest → created during the run → scan from byte 0, EXCEPT
   a `{name}.log.1` whose `{name}.log` was baselined: that is a mid-run rotation, so inherit the
   parent's baseline offset (else every pre-baseline error in it resurfaces as new).
7. Otherwise same byte-offset + rotation logic as source 1; per-file diffs land in
   smoke/raw/S8/logs/{name}.diff.
8. Parse each group's Monolog level and apply the policy table below.

Source 3 — var/report/**
9. Walk recursively. A file is a signal when its path is absent from the baseline manifest, or
   its mtime moved past the baselined mtime.
10. Decode (JSON, or PHP-serialized on older versions, or raw — never dropped silently) and copy
    to smoke/raw/S8/reports/{name}.json.

11. Write smoke/raw/S8/signals.json and exit 1 (gating), 4 (recorded only), or 0 (nothing).
```

An "exception group" is detected by Magento's own log format: a line matching
`[<ts>] <channel>.<LEVEL>:` starts a new group; subsequent indented or non-timestamped lines
belong to the same group. Lines *before* the first header in a diff belong to a group that
straddled the baseline offset — they are reported as `log_unparsed` (Medium), never discarded.

---

## Level policy

`cron.log` on a real store carries six figures of INFO lines during a smoke window, so "any new
byte fails" is unusable outside `exception.log`. Only ERROR and above is a candidate signal:

| Source | Gates the loop | Recorded (Medium) | Ignored |
|--------|----------------|-------------------|---------|
| `exception.log` (+`.1`) | every new group, any level | allowlisted groups | — |
| `system.log`, module channels, anything else `*.log` | EMERGENCY / ALERT / CRITICAL / ERROR — see attribution | WARNING; unattributed ERROR | NOTICE / INFO / DEBUG |
| `debug.log` | never — it duplicates the other streams | ERROR+ | rest |
| `cron.log`, `magento.cron.*.log`, `*consumer*`, `*queue*` | ERROR+ **only when the feature declares a cron/queue surface** | ERROR+ otherwise | WARNING and below |
| `var/report/**` (incl. `api/`) | every new or refreshed file | allowlisted reports | — |

### Attribution

Broadening the gate to every log would re-create the FI-1 problem (see "How fixes interact with
the baseline") on any site with background noise: unfixable findings pinning every run to the
5-iteration cap. Attribution is what keeps it usable. `smoke-tail-since.sh --namespace=` takes
the feature's modules; the runner passes every module the feature owns.

| Case | Severity | Gating |
|------|----------|--------|
| Group text names `Vendor_Module` / `Vendor\Module` / `Vendor/Module` | Critical | yes |
| CRITICAL+ in a gated log, no namespace match | High | yes |
| Plain ERROR, no namespace match | Medium | no |
| Report file naming the namespace | Critical | yes |
| Report file not naming the namespace | High | yes |

A report file always gates: it means a request died. Unattributed CRITICAL+ gates too — a broken
layout or DI wire frequently surfaces as a core-namespace critical with no mention of the
feature. Genuine background criticals (the canonical one being
`A symlink for ".../requirejs-config.js" already exists` after a deploy) belong in the allowlist.

Findings are **aggregated by signature** — timestamps, hex ids, numbers and paths normalised —
so one broken plugin firing 40 times is one finding with `occurrences: 40`, not 40 findings.

---

## Allowlist

A site may have legitimate noise it knows is unrelated to the smoke run. The user opts in via
`CLAUDE.md`:

```
Smoke exception ignore:
  - ^Cron \w+ heartbeat OK$
  - A symlink for .* already exists
```

Each line under `Smoke exception ignore:` is a **Python `re`** pattern — the engine S8 actually
compiles them with. It is close to PCRE but not identical: `\K`, recursion and possessive
quantifiers do not exist, so do not port a PCRE-only construct here. A group (or report message)
matching **any** pattern is demoted to Medium, marked `allowlisted`, and stops gating. The skill reads
CLAUDE.md at S1, writes the patterns to `smoke/allowlist.txt`, and passes
`--allowlist=smoke/allowlist.txt` at S8. An invalid pattern is reported in `degraded[]` — it is
never silently skipped.

The allowlist is intentionally not stored in the skill — it is per-site and per-deployment.

---

## Exit codes and degradation

| Code | Meaning |
|------|---------|
| 0 | no signals |
| 1 | at least one gating signal — 6B fails, findings route to fix delegates |
| 2 | baseline missing or malformed |
| 3 | live log path could not be located |
| 4 | non-gating signals only — recorded in findings.md, does not fail the iteration |
| 5 | **scan degraded**: python3 unavailable, or the baseline predates the manifest sections. `exception.log` was still diffed, but sources 2 and 3 were **not** checked. Record a Medium finding for reduced coverage and say so in the run report — never read a 5 as a clean run. |

`signals.json` carries a `degraded[]` array for partial coverage that is not fatal: a missing
`var/report` directory (no report has ever been written on this install), an unreadable log, a
findings-cap overflow, or an invalid allowlist pattern. Every cap is reported with its count —
no silent truncation.

---

## What does NOT count as a finding

- Lines that pre-date the baseline (i.e. existed before S1) — those were already there and are
  not the smoke run's responsibility. This includes a log that rotates *during* the run: the new
  `{name}.log.1` is the file we baselined under its old name, so it is read from the pre-rotation
  baseline offset, not from byte 0. Only a `.log.1` with no baselined parent is scanned whole.
- NOTICE / INFO / DEBUG in any log, and WARNING outside `system.log`/module channels.
- `debug.log` at any level as a *gate* — it mirrors the other handlers, so gating on it would
  double-count. ERROR+ there is still recorded.
- A report file that disappeared between S1 and S8 (deploy tooling cleans `var/report`).

---

## How fixes interact with the baseline

The baseline is captured **once per skill run**, not once per Phase 6 iteration — so the S8
diff (live signals minus baseline) ACCUMULATES everything recorded since the run started, and a
group never leaves the diff just because it was fixed.

Because of that, the S8 pass criterion is **"no new or unresolved gating signals"**, NOT
"the diff is empty". An empty-diff criterion is unsatisfiable once any exception has ever been
logged in the run: iteration 1's exception stays in the diff at iterations 2–5 even after it is
fixed, which would force the loop to the 5-iteration cap every time (FI-1). Instead:

- Every gating signal in `signals.json` is tracked in `findings.md` with a status, keyed by its
  `signature` (stable across iterations — that is what makes cross-iteration memory work).
- A signal whose fix landed in an earlier iteration is marked `resolved` — its lingering bytes
  in the diff are EXPECTED and do **not** fail S8.
- S8 fails 6B only when a gating signal is **new** (first seen this iteration) or still
  **unresolved**.
- The "5 iterations" cap still bounds pathological loops; `findings.md` carries the
  cross-iteration memory so resolved signals are not re-counted.

If a fix legitimately needs to rotate a log (rare — typically only when iteration 1's exception
was so large it interferes with diffing), the fix delegate writes a one-line note to
`smoke/baseline.txt` and re-captures. This is logged in the iteration report and counts as a
finding (Medium) in its own right.

---

## File locations

If no Magento root can be resolved, S1 exits 2 and reports "no Magento root found" — which is
itself a finding (Medium): either the path is wrong or the layout is unexpected. A resolved root
whose `var/log/exception.log` does not exist yet is normal on a fresh install and is recorded as
`size_bytes=0`, not an error.
