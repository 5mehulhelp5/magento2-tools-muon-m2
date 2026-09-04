---
name: widget
version: 1.0.0
description:
    Scaffold a Magento 2 CMS widget on an existing module — the `etc/widget.xml` declaration
    (parameters, containers, templates), the `Magento_Widget` module sequence, a
    `BlockInterface` block with typed parameter accessors and a parameter-aware cache key,
    a theme-neutral `.phtml` template, and unit + integration tests. Use for 'add a widget',
    'create a widget.xml', 'make X insertable from Content → Widgets, the WYSIWYG editor,
    or a widget directive in CMS content'. NOT for jQuery-UI `$.widget` / Breeze JS
    widgets — that is frontend JS work: use magento2-tools:frontend (RequireJS / Knockout /
    Alpine) or magento2-tools:breeze-adapt. For a new module use
    magento2-tools:module-create first.
---

# Magento 2 CMS Widget Scaffold

Scaffold a CMS widget onto an **existing** Magento 2 module. A widget is a block that a
store admin can drop onto pages without touching code — from **Content → Widgets** (a
*widget instance* bound to layout containers), from the WYSIWYG editor's *Insert Widget*
button, or from a `{{widget type="..." ...}}` directive inside CMS page/block content.
Produces `etc/widget.xml`, the `Magento_Widget` dependency, the block class, the storefront
template, and the tests that prove the parameter contract.

## Core Rules

- **Widget id convention:** `{vendor_lower}_{module_lower}_{widget}` — all lowercase,
  underscore-separated, where `{vendor_lower}` / `{module_lower}` are the snake_case forms
  from `context/references/naming.md` (`OrderExport` → `order_export`) and `{widget}` is
  the snake_case widget class name **minus a duplicated leading `{module_lower}_`**:
  `Acme_Promo` + `PromoBanner` → `acme_promo_banner`; `Acme_Promo` + `Countdown` →
  `acme_promo_countdown`. The id is an `xs:ID` in the merged widget config of every
  module on the instance, so the vendor + module prefix is what keeps it collision-free.
- **The block contract.** The class extends `Magento\Framework\View\Element\Template` and
  implements `Magento\Widget\Block\BlockInterface` (the marker the widget filter checks
  before rendering; a block without it renders as an empty string). `$_template` holds the
  fully-qualified path `{Vendor}_{Module}::widget/{template_name}.phtml` so it resolves
  through theme overrides and Hyvä compatibility modules.
- **Every parameter arrives as a string.** Widget instances inject parameters through a
  generated layout update (`<action method="setData">`), directives pass them as attribute
  strings, and multiselects arrive comma-joined. The block owns **typed accessors** with
  defaults and coercion (`getTitle(): string`, `getItemsCount(): int`,
  `isShowTitle(): bool`); templates never read raw `getData()`.
- **Parameter-aware cache key.** Override `getCacheKeyInfo()` to append every parameter
  value to `parent::getCacheKeyInfo()`. Block-HTML caching only activates when
  `cache_lifetime` is set, but a widget that forgets this serves one instance's cached
  fragment for every other instance the moment someone enables it.
- **No business logic in the block.** Data loading (products, CMS entities, API calls)
  belongs in a constructor-injected service or ViewModel the block delegates to. Tests mock
  the delegate. A widget that renders persisted entities also implements
  `Magento\Framework\DataObject\IdentityInterface` so full-page cache invalidates on save.
- **Theme-neutral template.** Plain PHP + semantic HTML, `$escaper` on every output, no
  jQuery / Knockout / RequireJS / `data-mage-init` assumptions — the same file renders under
  Luma, Hyvä (Tailwind classes need the module registered for scanning), and Breeze.
  JS behaviour is a separate task for `frontend` or `breeze-adapt`.
- **`<containers>` ↔ `template` parameter contract.** Each `<container>/<template value>`
  must equal an `<option name>` of the `template` select parameter; otherwise that
  container offers no template in the widget-instance form. Omit `<containers>` entirely
  to allow every layout container.
- **Selects need a source.** `select` / `multiselect` parameters declare either inline
  `<options>` (`selected="true"` = the form default — the scaffold's Yes/No `show_title`
  works this way and needs no extra module) or `source_model="..."` (an
  `OptionSourceInterface`; no declarable default, and a source from another module —
  `Magento\Config\Model\Config\Source\Yesno` is `Magento_Config`'s — is a dependency to
  declare like any other). `<value>` on a `text` parameter is its form default.
- **Declare every dependency.** `etc/module.xml` gains
  `<sequence><module name="Magento_Widget"/></sequence>` and `composer.json` gains a
  **bounded** `magento/module-widget` requirement; every other module whose class
  `widget.xml` names (a source model, a chooser block, `Magento_CatalogWidget` for
  `conditions`) is declared the same way. Widget declarations are read from the merged
  `widget.xml` config, so after any edit run
  `{ctx.magento_cli} cache:clean config block_html full_page layout`; a changed sequence
  additionally needs `{ctx.magento_cli} setup:upgrade`.
- **Email compatibility is opt-in.** `is_email_compatible="true"` lists the widget in the
  email-template editor; such widgets must emit inline-styled, JS-free HTML with absolute
  URLs. Default is `false`.
- **PHPCS / coding style.** Generated PHP follows PER-CS 3.0 as the baseline with the
  Magento 2 coding standard taking precedence; `--standard=Magento2` is the gate.
  `declare(strict_types=1)` on every file; no `final` on any class.
  See `context/references/php-coding-style.md`.
- **Source of truth.** Generate from templates → shared references → baked-in Magento 2 knowledge
  → official Magento/Adobe docs (live-fetched only when uncertain). Do NOT read, grep, or "study"
  other modules under `app/code`/`vendor/*`/Magento core to infer conventions, entity shapes,
  naming, or wiring. Narrow exceptions: the target module/class of this operation, and the specific
  contract of a module this code explicitly depends on. Affirm sources in the final report. See
  `context/references/source-of-truth.md`.

## Workflow

### Phase 0 — Context Resolution

Invoke `context` (or run
`${CLAUDE_PLUGIN_ROOT}/skills/context/scripts/resolve-context.sh`); capture the
JSON as `{ctx}`. Abort if `{ctx.magento_root}` is unresolved.

**Hard stop if the target module does not exist.** Check
`{ctx.magento_root}/app/code/{Vendor}/{Module}/registration.php`. If absent, offer
`module-create` and abort — do not scaffold into a non-existent module.

Read `{ctx.theme.frontend}` and `{ctx.theme.breeze}` for the theme notes in Phase 5. They
do not change what is generated — the template is theme-neutral — but they change the
follow-up advice (Hyvä Tailwind registration, Breeze JS routing). A `null` theme is
reported as "active theme unknown", never assumed to be Luma. Note `{ctx.magento_version}`
for the integration-test attribute choice in Phase 3.

### Phase 1 — Resolve Inputs

Ask for any missing values in one batch. The flags in **Inputs** cover identity only;
parameters, containers and the data source are collected conversationally.

| Input | Default | Notes |
|-------|---------|-------|
| Module | (ask) | Existing `{Vendor}_{Module}` |
| Widget class name | (ask) | PascalCase, e.g. `PromoBanner`; placed in `Block/Widget/` |
| Widget id | derived | `{vendor_lower}_{module_lower}_{widget}` per the Core Rule, e.g. `acme_promo_banner`; `--id` overrides |
| Widget label | (ask) | Shown in the admin widget-type dropdown and WYSIWYG insert dialog |
| Widget description | (ask) | One sentence, shown next to the label in admin |
| Parameters | template set | Per parameter: name, `xsi:type` (`text` / `select` / `multiselect` / `block` / `conditions`), label, required, default, `<options>` or `source_model`, `depends`. The template ships `title` (text, required), `show_title` (inline Yes/No select, default Yes), `items_count` (text, default 5), `template` (select) — extend or replace |
| Template file name | derived | snake_case of the class name (`PromoBanner` → `promo_banner`) → `view/frontend/templates/widget/{template_name}.phtml` |
| Containers | `content`, `sidebar.main`, `sidebar.additional` | Restricts placement in the widget-instance form; say "unrestricted" to omit `<containers>` |
| Email compatible | `false` | `true` only for JS-free, inline-styled output |
| Placeholder image | none | Optional `{Vendor}_{Module}::images/widget/{widget_id}.png` shown in the WYSIWYG editor; the default Magento placeholder is used when absent |
| Data source | none | Optional service / repository the block delegates to; when set, the block also implements `IdentityInterface` |

See `${CLAUDE_SKILL_DIR}/references/widget-anatomy.md` and
`${CLAUDE_SKILL_DIR}/references/parameter-types.md`.

### Phase 2 — Plan

Present every file to create or modify. Typical file set:

- `etc/widget.xml` (merge)
- `etc/module.xml` (merge — `Magento_Widget` sequence, plus any borrowed module)
- `composer.json` (merge — bounded `magento/module-widget` requirement, plus any borrowed module)
- `Block/Widget/{WidgetName}.php`
- `view/frontend/templates/widget/{template_name}.phtml`
- `Test/Unit/Block/Widget/{WidgetName}Test.php`
- `Test/Integration/Widget/{WidgetName}DeclarationTest.php`

Wait for "proceed."

### Phase 3 — Test First, then Generate

**3A — Write the failing tests (RED).** Write the tests that pin the parameter contract,
then scaffold only the block's *signature* so the tests have a type to bind to — the
interface-first seam from `context/references/tdd-discipline.md`:

1. Write `Test/Unit/Block/Widget/{WidgetName}Test.php` from
   `${CLAUDE_SKILL_DIR}/templates/test-widget-block-unit.php` and
   `Test/Integration/Widget/{WidgetName}DeclarationTest.php` from
   `${CLAUDE_SKILL_DIR}/templates/test-widget-declaration-integration.php`.
2. Write `Block/Widget/{WidgetName}.php` from
   `${CLAUDE_SKILL_DIR}/templates/widget-block.php` with the body of every accessor and of
   `getCacheKeyInfo()` replaced by `throw new \RuntimeException('not implemented');`. The
   class declaration, interface, constant and `$_template` stay as generated — that part is
   exempt scaffold.
3. Run the unit test:
   `{ctx.runner} vendor/bin/phpunit -c dev/tests/unit/phpunit.xml.dist app/code/{Vendor}/{Module}/Test/Unit/Block/Widget`
   — every behaviour test must fail on the `not implemented` exception (behaviour missing),
   not on an autoload path or PHPUnit setup error. Only the marker-interface test passes at
   this point, because the interface is part of the exempt scaffold.

The unit test must:

- Build the block with a mocked `Template\Context` whose `getStoreManager()`,
  `getResolver()`, `getAppState()`, and `getUrlBuilder()` return configured mocks — that
  is what `parent::getCacheKeyInfo()` touches. No Magento bootstrap required.
- Assert every accessor falls back to its default when the parameter is absent.
- Assert string coercion: `'12'` → `12`, `'0'` → `false`, `'1'` → `true`.
- Assert the invalid counts `'0'`, `'-3'`, `'abc'`, `''` each fall back to the default (one
  test, one assertion per value with a message naming the value).
- Assert `getCacheKeyInfo()`'s appended tail equals the parameter values exactly (order and
  types included — a bare `assertContains` can be satisfied by the parent's own entries), is
  identical for two blocks
  with identical parameters, and differs when **any** parameter differs (`title`,
  `items_count`, `show_title` each get a case).
- No `markTestIncomplete`, no `self::assertTrue(true)`.

The integration test covers the config XML the unit test cannot: the merged widget config
contains `{widget_id}`, its `type` is the block FQCN, the declared parameters are present,
and the block renders the title through the template in the `frontend` area. It carries a
`setUp()` guard that skips — with the exact reason — when the integration framework is not
loaded; keep the guard. On Magento < 2.4.5 replace `#[AppArea('frontend')]` with the
`@magentoAppArea frontend` annotation. Run it with
`{ctx.runner} vendor/bin/phpunit -c dev/tests/integration/phpunit.xml {ctx.magento_root}/app/code/{Vendor}/{Module}/Test/Integration`;
when `{ctx.magento_cli}` is null or `dev/tests/integration/etc/install-config-mysql.php` is
absent, the test cannot run — say so in the report (the tiered fallback in
`context/references/tdd-discipline.md`), never call it passed.

**3B — Generate implementation (GREEN).** Replace the throwing bodies in
`Block/Widget/{WidgetName}.php` with the real ones from the template and write the
remaining files:

- `${CLAUDE_SKILL_DIR}/templates/widget.xml`
- `${CLAUDE_SKILL_DIR}/templates/module.xml`
- `${CLAUDE_SKILL_DIR}/templates/widget-block.php`
- `${CLAUDE_SKILL_DIR}/templates/widget-template.phtml`

Keep the parameter artefacts in lockstep: every `<parameter name>` in `widget.xml` has one
typed accessor in the block, one assertion group in the unit test, and (when rendered) one
escaped output in the template — except `template`, which the framework consumes to pick
the `.phtml` and which no accessor reads. Adding a parameter means touching all three.

See `${CLAUDE_SKILL_DIR}/references/widget-anatomy.md`,
`${CLAUDE_SKILL_DIR}/references/parameter-types.md`, and
`${CLAUDE_SKILL_DIR}/references/pitfalls.md`.

### Phase 4 — Verify

- `php -l` on every generated `.php` and `.phtml` file.
- `xmllint --noout` on every generated `.xml` file — well-formedness only. When
  `{ctx.magento_root}/vendor/magento/module-widget/etc/widget.xsd` exists, also validate
  `etc/widget.xml` against it with the XML-catalog recipe in
  `${CLAUDE_SKILL_DIR}/references/widget-anatomy.md` (a misspelled attribute passes
  `--noout` and fails only there or at runtime).
- Run the Phase 3A unit test again and confirm it now **passes** (it failed before 3B);
  run the integration test where the framework is available; run the module suite to
  confirm nothing else broke.
- **Apply the shared module-hygiene baseline (required).** After generating or modifying
  PHP files, run
  `${CLAUDE_PLUGIN_ROOT}/skills/context/scripts/add-license-headers.sh {ctx.magento_root}/app/code/{Vendor}/{Module} {Vendor}`
  to stamp the standard copyright header onto every new `.php` (idempotent — it skips files
  that already carry it). When adding a `composer.json` `require` entry, resolve a
  **bounded** constraint via
  `${CLAUDE_PLUGIN_ROOT}/skills/context/scripts/resolve-dep-constraint.sh magento/module-widget` —
  never `"*"`. See `context/references/module-hygiene.md`.
- Run `review --diff` (gate: zero Critical/High findings).
- Consult `${CLAUDE_SKILL_DIR}/references/pitfalls.md` before declaring Phase 4 done.

### Phase 5 — Report

Write a brief Markdown report to
`{output_root}/widgets/{Vendor}_{Module}-{widget_id}-{date}.md` listing:

- Widget id, label, block FQCN, and the parameter table (name / type / default)
- Files generated
- Test path + red→green evidence (and any honestly skipped integration test)
- Activation: `{ctx.magento_cli} setup:upgrade` (sequence change) then
  `{ctx.magento_cli} cache:clean config block_html full_page layout` — when
  `{ctx.magento_cli}` is null, print `bin/magento` and say the CLI was not resolved
- The three placement paths — **Content → Widgets → Add Widget** (type = the label),
  the WYSIWYG *Insert Widget* button, and the directive form
  `{{widget type="{Vendor}\{Module}\Block\Widget\{WidgetName}" title="..." items_count="5"}}`
  — plus the layout-XML `<block class="..." template="...">` form for developers
- Theme notes: Hyvä → register the module for Tailwind scanning if the template uses
  utility classes; Breeze active → any JS behaviour goes through `breeze-adapt`;
  `theme.frontend` null → "active theme unknown"
- Sources affirmed (templates / references / official docs fetched, if any)

> **Docs may now be stale.** This change modified module code. Run
> `docs --module={Vendor}_{Module}` to refresh the module's README,
> CHANGELOG, and `docs/*.md` (technical reference, guides, and API references as
> applicable).

## Inputs

```
/widget --module=Acme_Promo --class=PromoBanner \
  --label="Promo Banner" --description="Configurable promotional banner" \
  [--id=acme_promo_banner] [--containers=content,sidebar.main] \
  [--email-compatible] [--placeholder-image=Acme_Promo::images/widget/banner.png] \
  [--docs-root=<path>]
```

`--docs-root=<path>` — output-root override; see "Output root" below. Parameters beyond
the template set are collected conversationally in Phase 1.

## Outputs

```
{ctx.magento_root}/app/code/{Vendor}/{Module}/etc/widget.xml                                  (merge)
{ctx.magento_root}/app/code/{Vendor}/{Module}/etc/module.xml                                  (merge)
{ctx.magento_root}/app/code/{Vendor}/{Module}/composer.json                                   (merge)
{ctx.magento_root}/app/code/{Vendor}/{Module}/Block/Widget/{WidgetName}.php
{ctx.magento_root}/app/code/{Vendor}/{Module}/view/frontend/templates/widget/{template_name}.phtml
{ctx.magento_root}/app/code/{Vendor}/{Module}/Test/Unit/Block/Widget/{WidgetName}Test.php
{ctx.magento_root}/app/code/{Vendor}/{Module}/Test/Integration/Widget/{WidgetName}DeclarationTest.php

{output_root}/widgets/{Vendor}_{Module}-{widget_id}-{date}.md
```

`{output_root}` defaults to `.docs` (`{ctx.docs_root}`), anchored at the project root, never
under `{ctx.magento_root}`, `app/code`, or a module dir. See the **Artifact location** rule in
`context/SKILL.md`.

### Output root (`--docs-root`)

This skill accepts `--docs-root=<path>` (see
`context/references/artifact-layout.md`). When set, write the run report (and any
report artifacts) under `<path>/widgets/`; otherwise default to
`{ctx.docs_root}/widgets/`. `feature` passes this so a feature run's
reports collect under its folder.

## Reference Files

- `${CLAUDE_SKILL_DIR}/references/widget-anatomy.md` — `widget.xml` structure and
  attributes, how parameters reach the block (instance layout update, directive, layout
  XML), the `<containers>` ↔ `template` contract, block/cache/identity rules, enablement
  and cache-clean commands, schema validation recipe.
- `${CLAUDE_SKILL_DIR}/references/parameter-types.md` — the `xsi:type` matrix (`text`,
  `select`, `multiselect`, `block`, `conditions`), `<options>` vs `source_model`, defaults,
  `depends`, `visible` / `required` / `sort_order`, and the runtime shape of each value.
- `${CLAUDE_SKILL_DIR}/references/pitfalls.md` — missing `BlockInterface`, undeclared
  dependencies, string coercion, cache-key collisions, container/template mismatch, id
  collisions, escaping, email-compatible constraints, Hyvä Tailwind purge, Breeze JS,
  stale config cache.
- `context/references/naming.md` — naming conventions (`{vendor_lower}` / `{module_lower}`
  derivation, class-name rules).
- `context/references/tdd-discipline.md` — shared test-first RED/GREEN loop, the
  interface-first seam, and the tiered fallback for integration tests.
- `context/references/php-coding-style.md` — PER-CS + Magento coding style.
- `context/references/placeholder-schema.md` — token registry.
- `context/references/theme-detection.md` — how `theme.frontend` / `theme.breeze` are
  resolved and why `null` must not be treated as Luma.
- `context/references/source-of-truth.md` — source-of-truth hierarchy + the
  no-unrelated-module-scanning rule (allowed reads, live-doc fetch protocol, report affirmation).

## Templates

- `templates/widget.xml` → `etc/widget.xml` (merge)
- `templates/module.xml` → `etc/module.xml` (merge — sequence only)
- `templates/widget-block.php` → `Block/Widget/{WidgetName}.php`
- `templates/widget-template.phtml` → `view/frontend/templates/widget/{template_name}.phtml`
- `templates/test-widget-block-unit.php` → `Test/Unit/Block/Widget/{WidgetName}Test.php`
- `templates/test-widget-declaration-integration.php` →
  `Test/Integration/Widget/{WidgetName}DeclarationTest.php`

All templates follow the placeholder registry in
`context/references/placeholder-schema.md`. Every token used must be in the
registry — `tests/test-placeholder-tokens.sh` enforces it.

## Acceptance Criteria

- All generated files pass `php -l` / `xmllint --noout`; `etc/widget.xml` validates
  against `widget.xsd` where a Magento root is available.
- Widget id follows `{vendor_lower}_{module_lower}_{widget}` — the vendor + module prefix
  is what rules out collisions; the integration test's class-type assertion would expose
  one anyway.
- `etc/module.xml` sequences `Magento_Widget` (and every module whose class `widget.xml`
  names); `composer.json` requires them with bounded constraints.
- The block extends `Template`, implements `BlockInterface`, sets a fully-qualified
  `$_template`, exposes one typed accessor per parameter (except `template`), and
  overrides `getCacheKeyInfo()` with every parameter value.
- Every `<container>/<template value>` matches an `<option name>` of the `template`
  parameter; every `select` / `multiselect` has `<options>` or `source_model`.
- The template escapes every output via `$escaper`, reads only typed accessors, and
  contains no jQuery / Knockout / RequireJS / `data-mage-init` markup.
- Unit test asserts defaults, coercion, and cache-key variance per parameter with real
  assertions and was watched to fail on the throwing stub first; integration test asserts
  the merged widget config and a frontend render (or is skipped with the exact reason
  recorded in the report).
- `review --diff` returns zero Critical/High findings.

## Related Skills

| Phase | Skill |
|-------|-------|
| 0 | `context` |
| Before (if module absent) | `module-create` |
| After | `review --diff` |
| JS behaviour for the widget (RequireJS / Knockout / Alpine) | `frontend` |
| Breeze-active store needing JS | `breeze-adapt` (scope with `breeze-compat` first) |
| Admin-configurable defaults for the widget | `system-config` |
