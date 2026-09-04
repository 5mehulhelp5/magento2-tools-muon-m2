# Widget Parameter Types

Reference for the `<parameter xsi:type="...">` matrix in `etc/widget.xml`, what each type
renders in the admin widget form, how it is declared, and — the part that bites — the
**runtime shape** of the value the block receives. Source: `Magento_Widget`'s
`etc/widget.xsd` and its config converter (`Model/Config/Converter.php`), which turns the
XML into the array the admin form and the widget filter consume.

## The matrix

| `xsi:type` | Admin field | Declaration | Runtime value in the block |
|------------|-------------|-------------|----------------------------|
| `text` | text input | optional `<value>` = form default | `string` (absent → `null`) |
| `select` | dropdown | `source_model="..."` **or** `<options>`; `selected="true"` on an option marks the default (a `source_model` select has no declarable default) | `string` — the option value; Yes/No options and sources give `"1"` / `"0"` |
| `multiselect` | multi-select list | same as `select` | comma-joined `string` from a widget instance or directive; a PHP `array` only when a layout `<argument xsi:type="array">` sets it |
| `block` | custom "chooser" renderer (button + picker) | `<block class="...Chooser"><data>...</data></block>` | `string` — the chosen entity id (e.g. `page_id`, `block_id`, `id_path`) |
| `conditions` | catalog rule condition tree | `class="Magento\CatalogWidget\Block\Product\Widget\Conditions"` | arrives as `conditions_encoded`; decode with `Magento\Widget\Helper\Conditions::decode()` |

Any `xsi:type` that is not one of these five is passed through as the form element type
(the XSD rejects unknown types in developer mode, so stay inside the matrix).

## Attributes common to every parameter

| Attribute | Required | Meaning |
|-----------|----------|---------|
| `name` | yes | `xs:NMTOKEN`; the `getData()` key in the block. snake_case. |
| `visible` | no | Absent → visible. `false` renders a **hidden** input that still submits `<value>` — the idiom for passing constants to the block (core uses it for `uiComponent`). |
| `required` | no | Present → required in the admin form unless the literal value is `false`. |
| `sort_order` | no | Integer display order in the form. Leave gaps (`10`, `20`, `30`). |

Child elements: `<label translate="true">` (field label), `<description translate="true">`
(rendered as the field note; CDATA allowed for `<br/>`), `<depends>`.

## Defaults — two different things

- `<value>` on a `text` parameter and `selected="true"` on a `select` / `multiselect` option
  set the **admin form's initial value**. They do nothing for a directive someone writes by
  hand, and an empty form field is dropped from the instance layout update entirely.
- Therefore the **block accessor** owns the runtime default: `getData('items_count')` is
  `null` whenever the parameter was blank, so `getItemsCount()` returns
  `self::DEFAULT_ITEMS_COUNT` in that case. Declare both, keep them equal.

## `source_model` vs `<options>`

```xml
<!-- shared source model: any Magento\Framework\Data\OptionSourceInterface -->
<parameter name="show_title" xsi:type="select" visible="true" sort_order="20"
           source_model="Magento\Config\Model\Config\Source\Yesno">
    <label translate="true">Show Title</label>
</parameter>

<!-- inline options: name is an NMTOKEN key, value is what the block receives -->
<parameter name="layout" xsi:type="select" required="true" visible="true" sort_order="30">
    <label translate="true">Layout</label>
    <options>
        <option name="grid" value="grid" selected="true">
            <label translate="true">Grid</label>
        </option>
        <option name="list" value="list">
            <label translate="true">List</label>
        </option>
    </options>
</parameter>
```

A `select` / `multiselect` with neither renders an empty dropdown. For a custom source
model, implement `toOptionArray()` returning `[['value' => ..., 'label' => __('...')], ...]`
and place it under `Model/Config/Source/` (the `system-config` skill ships the same shape).

Two consequences of choosing `source_model`:

- **It cannot declare a default.** The form shows the source's first option; there is no
  `selected` equivalent. When the default matters — a Yes/No that should start at *Yes* —
  use inline `<options>` with `selected="true"` (what the scaffolded `show_title` does).
- **It is a dependency.** A source model from another module (`Magento_Config`'s `Yesno`,
  `Magento_Catalog`'s sort-by sources) adds that module to `module.xml` `<sequence>` and to
  `composer.json`, exactly like a borrowed chooser.

## `depends` — conditional visibility

```xml
<parameter name="items_count" xsi:type="text" required="true" visible="true" sort_order="30">
    <label translate="true">Number of Items</label>
    <depends>
        <parameter name="show_items" value="1"/>
    </depends>
    <value>5</value>
</parameter>
```

The field is shown only while `show_items` equals `1`. Repeating the same `name` with
several `value`s makes it "any of". Dependencies are client-side only (the admin form's
dependence JS); the block still receives whatever was last saved, so accessors must not
assume a hidden field is empty.

## `block` — chooser parameters

Reuse a core chooser instead of building one:

| Picks | `class` |
|-------|---------|
| CMS page | `Magento\Cms\Block\Adminhtml\Page\Widget\Chooser` (value → `page_id`) |
| CMS block | `Magento\Cms\Block\Adminhtml\Block\Widget\Chooser` (value → `block_id`) |
| Product | `Magento\Catalog\Block\Adminhtml\Product\Widget\Chooser` (value → `id_path`, e.g. `product/42`) |
| Category | `Magento\Catalog\Block\Adminhtml\Category\Widget\Chooser` (value → `id_path`, e.g. `category/7`) |

```xml
<parameter name="block_id" xsi:type="block" visible="true" required="true" sort_order="10">
    <label translate="true">Block</label>
    <block class="Magento\Cms\Block\Adminhtml\Block\Widget\Chooser">
        <data>
            <item name="button" xsi:type="array">
                <item name="open" xsi:type="string" translate="true">Select Block...</item>
            </item>
        </data>
    </block>
</parameter>
```

Add the owning module (`Magento_Cms`, `Magento_Catalog`) to `module.xml` `<sequence>` and
`composer.json` when you borrow its chooser.

## `conditions` — catalog rule trees

```xml
<parameter name="condition" xsi:type="conditions" visible="true" required="true" sort_order="10"
           class="Magento\CatalogWidget\Block\Product\Widget\Conditions">
    <label translate="true">Conditions</label>
</parameter>
```

Requires `Magento_CatalogWidget` in `<sequence>` / `composer.json`. The block receives the
rule under `conditions_encoded` and must decode it (see how
`Magento\CatalogWidget\Block\Product\ProductsList` builds its collection). Only reach for
this when the widget genuinely filters catalog products by rule.

## The `template` parameter

A `select` named exactly `template` is special twice over:

1. Its value is applied as the block's template (the directive path passes it as data; the
   widget-instance path writes it as the `template=""` attribute of the generated layout
   block), overriding the block's `$_template` default.
2. Its option **names** are what `<containers>/<container>/<template value="...">` refer to
   — see `widget-anatomy.md`.

Use fully-qualified values (`{Vendor}_{Module}::widget/{template_name}.phtml`) so the same
path works from every entry point and through Hyvä compatibility-module fallback.
