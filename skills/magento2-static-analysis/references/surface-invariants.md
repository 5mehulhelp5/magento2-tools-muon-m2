# Surface Invariants

Cross-file completeness rules run by `${CLAUDE_SKILL_DIR}/scripts/surface-invariants.sh` as part
of the Phase 2 analysis pass. They need no external tool — pure file inspection — so they always
run, even where phpcs/phpstan are unavailable.

## Why this pack exists

Every rule below was derived from a defect observed in production work, where a generator emitted
**N−1 of the N files a surface needs**, and every existing gate passed:

- XSD validation passed — each file was individually valid.
- `setup:di:compile` passed — nothing referenced a missing class.
- PHPUnit passed — **because the tests mocked the very collaborator whose wiring was missing.**
- phpcs and phpstan passed — they see one file at a time.

The failure appeared only at runtime, and often silently: an empty grid, a never-resolving admin
loader, a message published into no queue, a 404 with no log entry. Three of the defects were
total admin lockouts.

These are not style rules. Each asserts a relationship **between** files that no single-file
linter can see: a topic declared here must have a publisher there; a class registered here must
implement an interface over there.

## Precision is the point

A rule that fires on correct code is worse than no rule — it trains the reader to skip the
category. `tests/test-surface-invariants.sh` therefore asserts two things equally: that a fixture
with one violation per rule produces **exactly** the expected rule ids, and that a fixture with
every surface correct produces **zero** findings. The clean-fixture assertion is the load-bearing
one.

Measured on 66 real modules across three stores: **1 finding**, itself a verified true positive
(a `db`-transport topic with no topology binding — `MysqlMq\Model\Driver\Exchange::enqueue()`
collects destinations by matching bindings to the topic, so that publish reaches zero queues and
drops the payload).

Findings and rule origins in this file are described by defect class, never by client module name
or internal report title — this repository is public.

Two false-positive classes were found and fixed during that sweep, and both are worth
remembering when adding a rule:

- A bare `'a/b/c'` string literal is far more often a **`scopeConfig` path** than a URL, and a
  module's config section id is usually identical to its route id. SI-11 matches only strings
  passed to a URL builder.
- Judging a class by its own file's text is not enough — a collection extending
  `Magento\Customer\...\Grid\Collection` inherits the SearchResult bridge from **core**. SI-06
  walks the inheritance chain into `vendor/magento` and skips (reporting on stderr) when an
  ancestor cannot be resolved.

## Rules

| Id | Severity | Asserts | Defect it came from |
|----|----------|---------|-------------------|
| SI-01 | high | A topic in `communication.xml` has a `queue_publisher.xml` entry (repo-wide — the publisher may live in a sibling module) | generated queue surface, publisher file omitted |
| SI-02 | high | A topic has a `queue_topology.xml` binding | same surface |
| SI-03 | high | A consumer's `queue` is a destination some binding creates | same surface |
| SI-04 | high | A `TagScope` subclass's `TYPE_IDENTIFIER` is registered in `cache.xml` | generated cache class, never registered |
| SI-05 | high | A cache type wired by di.xml is not received by a parameter typed `App\CacheInterface` | cache type injected under the wrong interface |
| SI-06 | high | A class registered in the `collections` array provides the `SearchResultInterface` bridge | generated grid bound to a vanilla collection |
| SI-07 | high | A form UI component declares a `template` item in its root data argument | generated admin form, missing template item |
| SI-08 | medium | A `dynamicRows` does not repeat its own name as `dataScope` | hand-written dynamicRows double-binding |
| SI-09 | **critical** | A foreign ACL resource id is re-declared under its owner's parent | generated acl.xml, wrong parent chain |
| SI-10 | high | The `collections` registration lives in global `etc/di.xml` | grid registration in an area di.xml |
| SI-11 | high | A URL built from this module's route resolves to a controller class | template route string vs controller class name |
| SI-12 | high | Every ACL parent id in the chain is declared by some module | unverified ACL parent path in a blueprint |

### Notes on the trickier rules

**SI-09 is critical, not high.** `Acl\Builder` merges every module's `acl.xml` into one tree and
adds each resource beneath its declared parent; the same id arriving under two parents raises
`Resource id '…' already exists in the ACL`. That throws from
`Backend\Model\Auth\Session::processLogin()`, so **nobody can log into the admin** — while the
storefront is untouched, which is why a storefront smoke test and an HTTP 302 on `/admin` both
still look green. A resource id is authoritative only from the module that owns its prefix;
accepting any module's declaration would let one module's mistake become the reference the next
module is judged against.

**SI-11 mirrors the router exactly.** `Router\ActionList::get()` computes its lookup key as
`str_replace('_', '\\', strtolower($module . '\controller' . $area . '\' . $ns . '\' . $action))`,
so an underscore becomes a **namespace separator**: `login/authenticate_post` looks for
`Controller\Login\Authenticate\Post`. The comparison is case-insensitive, so camelCase vs
lowercase is fine — only the segment *shape* matters. The rule also applies the router's
reserved-word suffix (`.../store/switch` → `SwitchAction`), taken verbatim from
`ActionList::$reservedWords`.

**SI-10 is about merge semantics, not tidiness.** Items in the `collections` array merge across
modules only in the global `etc/di.xml`; in an area file each module's array replaces rather than
unions, so registering there silently drops other modules' grid data sources — including core
grids such as Customers. The symptom surfaces in an unrelated module, which is what made the
original bug expensive to trace.

## Degradation

Never silent. Written to stderr, which `build-findings.sh` turns into the document's
`scanner_errors`:

- an unparseable XML file is **named**, and the checks depending on it are skipped (treating a
  broken file as absent would turn it into a clean bill of health);
- a missing `vendor/` tree means the ACL reference set is unavailable, so SI-09 — an
  admin-lockout class — is reported as **not checked** rather than passing;
- a collection whose base-class chain cannot be resolved is skipped by name;
- a `TagScope` subclass with no `TYPE_IDENTIFIER` constant is skipped by name;
- non-`module` scope is reported as not checked: every rule reasons about one module's file set,
  so a site/diff run must invoke the checker per changed module.

## Adding a rule

1. Start from a real defect, not a hypothetical. Describe its class; do not cite client
  module names or internal report titles in this public repo.
2. Encode the mechanism from **vendor source**, not from memory or a report's paraphrase — two
  rules here were nearly encoded wrong (the router's underscore handling and the reserved-word
  suffix) and only reading `ActionList.php` got them right.
3. Add a violating case to the dirty fixture *and* the nearest-miss correct shape to the clean
  fixture. The second one is what keeps the pack trustworthy.
4. Prefer skipping to guessing. A rule that cannot decide must say so on stderr.
