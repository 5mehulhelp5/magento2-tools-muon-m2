# Theme Detection

Algorithm for resolving `theme.frontend` and `theme.adminhtml`.

## Honest gaps rule

Both fields are emitted as `null` when no evidence-backed value can be determined. The
resolver **never** silently defaults to `"custom"` or `"magento/backend"`. Consumers
that see `null` MUST treat it as "active theme unknown" and not assume Luma defaults.

Each field is accompanied by a `theme.{field}_source` string in the JSON. When the
value is `null`, the source is `null` or an empty string. When the value is non-null,
the source describes how it was derived (e.g. `"src/app/etc/config.php:themes[].area=frontend"`).

## `theme.frontend`

1. **`app/etc/config.php` `themes` array.** If present, prefer a registered `area = "frontend"`
   entry that is not under `Magento/`; fall back to any non-`Magento/blank` entry, then the first.
    - `theme.frontend = "<theme_path>"`.
    - `theme.frontend_source = "<config.php path>:themes[] registered (active theme unverified …)"`.
    - The resolver checks `src/app/etc/config.php` first, then `app/etc/config.php`.
    - **Not authoritative, and frequently absent.** The `themes` key is written by some install
      paths and not others; a composer-installed store routinely has no `themes` key at all. The
      genuinely authoritative source is the database (`core_config_data design/theme/theme_id`),
      which this resolver does not read — hence "unverified" in every source string below.

2. **Hyva package presence (heuristic).** If step 1 produced no result and
   `composer.json` requires any `hyva-themes/*` package, classify as `hyva`.
    - `theme.frontend = "hyva"`.
    - `theme.frontend_source = "<composer.json>:hyva-themes/* dependency (installed, active-theme unverified)"`.
    - The source string explicitly notes this is package-presence evidence, not
      active-theme confirmation.

3. **Component registration scan (filesystem).** The scan itself **always runs** (wherever PHP is
   available) — the theme map it builds is what the Breeze parent-chain walk below consumes, so
   it is not gated on steps 1–2. Only its *pick* is conditional: the discovered theme is adopted
   as `theme.frontend` only when steps 1–2 produced no result. The pick is the **leaf** of the
   parent chain. Two registration shapes are indexed, because a theme is a component like any
   other:
    - `app/design/frontend/<Vendor>/<theme>/theme.xml` — path from the directory.
    - `vendor/<vendor>/<pkg>/registration.php` declaring `ComponentRegistrar::THEME` with a
      `frontend/<Vendor>/<theme>` path — parent read from the sibling `theme.xml`. Both the
      single-line and the multi-line (trailing-comma) call forms are matched. The glob is pinned
      to package roots, so a `theme.xml` inside a package's test fixtures is never indexed as a
      real theme.

   A theme that something else inherits from is a base, not the storefront theme, so the
   candidates are the non-`Magento/` themes that are nobody's parent. With exactly one candidate
   the pick is recorded as the sole leaf; with several, the first in sorted order is taken and
   the source string records the candidate count, so the ambiguity is visible rather than implied.
    - `theme.frontend_source = "component registration scan (<n> frontend themes; … — active theme unverified, confirm via 'config:show design/theme/theme_id')"`.

4. **No evidence.** Leave `theme.frontend = null`. Do **not** fall through to
   `"custom"`. Downstream skills that need the active theme must surface an honest
   "unknown" rather than acting on a fabricated default.

## `theme.adminhtml`

Resolved the same way as `theme.frontend`, from the `area = "adminhtml"` entry in
`app/etc/config.php`. When no entry exists, leave it `null`. Do **not** default to
`Magento/backend` — that assumption was previously baked in and produced misleading
"resolved" state for projects that hadn't yet run setup.

## Breeze detection (`theme.breeze`)

Swissup [Breezefront](https://breezefront.com) is a frontend framework that replaces
RequireJS/Knockout/jQuery with a Cash-based stack. It is detected independently of
`theme.frontend` and emitted as a `theme.breeze` object:

```json
"breeze": { "installed": false, "active": false, "parent": null, "packages": [], "source": null }
```

1. **`installed`** — `true` when `composer.json` `require` lists any `swissup/breeze-*`
   package (`breeze-blank`, `breeze-evolution`, `breeze-enterprise`) **or**
   `swissup/module-breeze`. `packages` collects every matched package name.

2. **`active`** — `true` only when the resolved `theme.frontend`, or any `<parent>` in its chain
   (walked up to 10 hops), is a Swissup Breeze theme (its code contains `breeze`). `parent` is
   set to that Breeze theme code (e.g. `Swissup/breeze-evolution`). Vendor-installed Breeze
   themes that are *directly* active are matched by the same "code contains breeze" rule.

   The chain is walked over the **full** theme map from step 3 of `theme.frontend` — both
   `app/design` and vendor packages. It previously read only
   `app/design/frontend/<code>/theme.xml`, which meant a Breeze storefront (whose themes are
   always composer packages) found no `theme.xml` at the first hop and stopped, reporting
   `active = false` on a store visibly serving Breeze. Combined with `theme.frontend` being
   `null` whenever `config.php` had no `themes` key — which also skipped the walk entirely — the
   field read `false` on exactly the installs it exists to identify.

   Because `active` gates every `breeze-*` skill and steers dimension selection in
   `audit`, a false negative silently drops Breeze coverage. That is worse than
   refusing outright: nothing signals the gap. Regression-guarded by
   `tests/test-context-breeze-vendor-theme.sh`.

   **Inference limit.** When the only non-`Magento/` theme registered is itself a Breeze theme,
   the resolver reports `active = true` — a store does not install and register a Breeze theme
   in order to run Luma. When the active theme's chain reaches a non-Breeze base instead,
   `active` stays `false` even with the packages installed. Neither case reads the database, so
   `theme.frontend_source` marks the pick unverified either way.

3. **Honest gaps.** With no evidence, `installed`/`active` stay `false`, `parent` is `null`.
   The walk spans both registration shapes indexed in step 3 — `app/design/frontend/<Vendor>/<theme>/`
   and `vendor/<vendor>/<pkg>/` package roots — so a custom child theme whose Breeze parent lives
   in `vendor/` now resolves. What stays out of reach is a theme registered outside those two
   shapes (a registration path deeper than a package root, or a symlinked path repository) and any
   chain longer than 10 hops: there the Breeze signal is reported via `installed` (package
   presence) alone, with the chain walk incomplete. `source` records which signal fired.

### Why it matters

The three `breeze-*` skills (`-child-theme`, `-module-adapt`, `-compat-audit`)
**refuse to run** when `theme.breeze.installed` is `false` and instead print the install
path (`composer require swissup/breeze-evolution && bin/magento setup:upgrade --safe-mode=1
&& bin/magento marketplace:package:install swissup/breeze-evolution`). `compat-audit` also
reads `active` to phrase its verdict ("compatible with the active Breeze theme" vs
"Breeze installed but not active").

## Output values

`theme.frontend` is one of:

- `null` when no evidence is available
- `"hyva"` (package-presence heuristic)
- A concrete theme code from `config.php` (e.g. `"Magento/luma"`, `"Acme/checkout"`)

`theme.adminhtml` is one of:

- `null` when no evidence is available
- A concrete theme code from `config.php` (e.g. `"Magento/backend"`, `"Acme/admin"`)

## Why it matters

Downstream skills behave differently per theme:

- `frontend` should refuse to generate Hyva/Luma-specific scaffolds
  when `theme.frontend` is `null`; instead, ask the user.
- `review` reads `theme.frontend_source` to decide whether RequireJS
  checks apply; if the source contains "installed, active-theme unverified", the
  reviewer notes the uncertainty in the finding.
- `module-create` `frontend_ui` surface should also branch on the source
  string, not just the value.

## Consumer pattern

```bash
THEME=$(jq -r '.theme.frontend // "null"' .claude/.cache/context.json)
SRC=$(jq   -r '.theme.frontend_source // ""'   .claude/.cache/context.json)

if [ "$THEME" = "null" ]; then
    echo "active frontend theme unknown; cannot generate theme-specific scaffold" >&2
    exit 1
fi
```
