# Magento 2 Log Targets

The canonical log-path reference is shared with the debug skill:
**`debug/references/log-locations.md`**. It lists the core Magento logs, custom-module
logs, container/infra logs, the runner-prefix reading pattern, time-window heuristics, and the
grep-patterns-by-symptom table. Resolve relative paths against `{ctx.magento_root}`.

This file used to duplicate that content (and had drifted); it now defers to it so the two
stay in sync.

## Bug-fix specifics

During Phase 1, grep the targets above and save, for each log file searched, to
`.docs/bug-fixes/{slug}/collect.md`:

- Path searched
- Pattern used
- Match count
- 3–5 sample matches with timestamps

`var/report/**` is a Phase 1 target in its own right, not an afterthought: it is recursive
(`var/report/xx/yy/{sha256}` when report-dir nesting is enabled) and `var/report/api/{id}` is
written on a REST/GraphQL PHP fatal with **no log entry anywhere**. Record, per report file:
the decoded message, the `url`, and the `report_id` (which appears alongside the `exception.log`
entry on 2.4.7+, letting you join the two — API reports have no such counterpart).

When the reporter says "there is nothing in the logs", record *which* sinks were actually
checked. An untouched `exception.log` is not evidence of no error — see the routing rule in
`log-locations.md`.

Do not paste raw log dumps into the conversation — group by error signature and surface the
top distinct entries.
