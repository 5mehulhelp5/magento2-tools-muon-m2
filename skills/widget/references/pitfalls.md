# Widget Pitfalls

Common mistakes and how to avoid them when scaffolding a CMS widget. Each one has cost a
debugging session — most because they produce no error at all, the last one because the
error it does produce names no file.

## 1. Block does not implement `BlockInterface`

The widget template filter creates the block, checks
`instanceof Magento\Widget\Block\BlockInterface`, and returns an **empty string** when the
check fails. No exception, no log line — the directive just vanishes from the page.
`implements BlockInterface` is mandatory; the unit test pins it.

## 2. Undeclared dependencies — `Magento_Widget` and anything you borrow

It "works on my machine" because `Magento_Widget` is always installed, but the module
then ships without its dependency: EQP / marketplace checks flag it, `module:enable`
ordering is undefined, and a store that disables `Magento_Widget` breaks on install.
Declare it in `module.xml` `<sequence>` and `composer.json` `require` (bounded
constraint via `resolve-dep-constraint.sh`). The same rule covers every class named in
`widget.xml`: a `source_model` such as `Magento\Config\Model\Config\Source\Yesno` adds
`Magento_Config`, a chooser adds `Magento_Cms` / `Magento_Catalog`, a `conditions`
parameter adds `Magento_CatalogWidget`. The scaffold uses inline `<options>` for its
Yes/No select precisely so that it depends on `Magento_Widget` alone.

## 3. Treating parameters as typed values

Every value arrives as a string: `"0"` is truthy in PHP, so
`if ($this->getData('show_title'))` shows the title when the admin chose **No**. Coerce in
one place — the accessor — with `filter_var($value, FILTER_VALIDATE_BOOLEAN)` for Yes/No
selects and `(int)` + a positive-range guard for counts. Templates call accessors only.

## 4. Relying on `<value>` for the runtime default

`<value>` seeds the admin form; a blank field is dropped from the saved instance, and a
hand-written directive can omit the parameter entirely, so `getData()` returns `null`.
The accessor supplies the default (`DEFAULT_ITEMS_COUNT`); keep it equal to `<value>`.

## 5. Cache-key collisions between instances

`Template::getCacheKeyInfo()` keys on store, template file and base URL — not on data.
Once anyone sets `cache_lifetime` (a widget parameter, a layout argument, a plugin), two
instances of the same widget with different parameters share one cached fragment and the
second instance renders the first one's content. Override `getCacheKeyInfo()` and append
**every** parameter value; the unit test asserts two differently-configured blocks produce
different keys.

## 6. `<containers>` templates that name nothing

`<container name="content"><template name="grid" value="grid"/></container>` only works if
the `template` select parameter has an `<option name="grid">`. A typo leaves the container
with an empty template dropdown in the widget-instance form and the admin cannot save the
layout update. Either keep the names in lockstep or omit `<containers>` entirely
(unrestricted placement, all `template` options offered everywhere).

## 7. Widget id collisions

`id` is an `xs:ID` across the **merged** config of every module. A generic id like
`banner` collides with the next extension that picks the same word, and the merge fails
schema validation in developer mode. Always `{vendor_lower}_{module_lower}_{widget}`.

## 8. Module-relative `$_template` paths

`protected $_template = 'widget/banner.phtml'` resolves against the module of the *class
that declares it* — fine until the block is subclassed from another module (a Hyvä
compatibility module, a project override) and the path silently resolves against the wrong
module. Use `{Vendor}_{Module}::widget/{template_name}.phtml` and the same fully-qualified
form in the `template` parameter's option values.

## 9. Unescaped output and `$this` in templates

Widget parameters are admin-entered strings that may contain anything. Every echo goes
through `$escaper->escapeHtml()` / `escapeHtmlAttr()` / `escapeUrl()`; use `$block`, never
`$this`, and never `getData()` directly in the template. PHPCS `Magento2` enforces the
first two; the third is a review finding.

## 10. Assuming a JavaScript stack

`data-mage-init`, `x-magento-init`, `require([...])`, and Knockout bindings work on Luma
only. Hyvä ships no RequireJS/Knockout; Breeze replaces jQuery. A widget template stays
plain PHP + HTML; interactive behaviour is a separate `frontend` (RequireJS/Alpine) or
`breeze-adapt` task, layered on top of the markup.

## 11. Hyvä purges unregistered Tailwind classes

Hyvä compiles only the classes Tailwind finds while scanning. A module's `.phtml` is
scanned only when the module is registered — `bin/magento hyva:config:generate` writes
`app/etc/hyva-themes.json` from modules that hook the `hyva_config_generate_before`
event, or the theme's `tailwind.config.js` lists the path explicitly. Otherwise utility
classes in the widget template are silently dropped from the production CSS. Either
register the module (see the Hyvä docs on Tailwind content settings) or use semantic
classes styled by the theme.

## 12. Stale config after editing `widget.xml`

Widget declarations live in the `config` cache; instance layout updates live in `layout` /
`full_page`. A widget that "does not appear" in Content → Widgets after adding
`widget.xml`, or an edited parameter that does not render, is almost always cache:
`bin/magento cache:clean config block_html full_page layout`. A changed `<sequence>` also
needs `bin/magento setup:upgrade` to re-sort the module list.

## 13. Email-compatible widgets that are not

`is_email_compatible="true"` offers the widget inside email templates. Email clients run no
JavaScript, ignore most CSS, and need absolute URLs — emit inline-styled table/anchor
markup and build URLs with `$block->getUrl()` under the emulated store. If the widget
needs a running page (pager, Alpine state, cart context), leave it `false`.

## 14. The `ttl` attribute does nothing

`widget.xsd` declares `ttl` on `<widget>` and core sets `ttl="86400"` on the New Products
widget, but the config converter never reads it. Fragment caching is controlled by the
block's `cache_lifetime` data (a `cache_lifetime` parameter, a layout argument, or
`setData('cache_lifetime', ...)` in the block) together with the cache key from #5.

## 15. Multiselect shape drift

A widget instance or directive delivers a multiselect as `"name,image,price"`; a layout XML
`<argument xsi:type="array">` delivers a PHP array. Normalise in the accessor:
`is_array($value) ? $value : array_filter(explode(',', (string) $value))`.

## 16. Entity-backed widgets without identities

A widget that renders products, categories, or CMS blocks must implement
`Magento\Framework\DataObject\IdentityInterface` and return the entities' cache tags from
`getIdentities()`; otherwise full-page cache keeps serving the old content after the entity
is saved. The scaffolded block leaves this out on purpose — add it together with the data
source, never for a static widget.

## 17. An XML comment inside `<options>` fatals the config converter

`Converter::_convertParameter()` walks the `<options>` children skipping only `#text`, then
reads `$option->attributes->getNamedItem('name')`. A `DOMComment` has **null** attributes,
so a comment between two `<option>` elements crashes the merge with
`Call to a member function getNamedItem() on null` — from `Magento\Widget\Model\Config\Converter`,
naming no file, on every page that reads the widget config.

The XSD permits comments anywhere, so `xmllint --schema` passes; only the converter objects.

```xml
<options>
    <!-- Yes must stay first: it is the form default. -->   <!-- FATAL -->
    <option name="yes" value="1" selected="true">
```

Comments elsewhere in `widget.xml` are safe and the scaffold uses them: the `<parameters>`
loop skips `#comment` explicitly, and `<containers>` filters on `instanceof DOMElement`. Put
the note above the `<parameter>` element instead of inside its `<options>`.
