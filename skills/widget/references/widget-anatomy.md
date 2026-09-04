# Widget Anatomy

Reference for the `etc/widget.xml` structure, the three ways a widget reaches a page and
how its parameters travel, the block / cache / identity rules, and the commands that make
a new declaration visible. Sources: `Magento_Widget` (`etc/widget.xsd`,
`Model/Config/Converter.php`, `Model/Template/Filter.php`, `Model/Widget/Instance.php`)
and the Adobe Commerce *Create a custom widget* tutorial
(developer.adobe.com/commerce/php/tutorials/frontend/create-custom-widget).

## widget.xml structure

Location: `{Vendor}/{Module}/etc/widget.xml` — merged with every other module's file into
one config keyed by widget id.

```xml
<?xml version="1.0"?>
<widgets xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:noNamespaceSchemaLocation="urn:magento:module:Magento_Widget:etc/widget.xsd">
    <widget id="{widget_id}"
            class="{Vendor}\{Module}\Block\Widget\{WidgetName}"
            is_email_compatible="false">
        <label translate="true">{WidgetLabel}</label>
        <description translate="true">{Description}</description>
        <parameters>
            <parameter name="title" xsi:type="text" required="true" visible="true" sort_order="10">
                <label translate="true">Title</label>
            </parameter>
            <parameter name="template" xsi:type="select" required="true" visible="true" sort_order="40">
                <label translate="true">Template</label>
                <options>
                    <option name="default" value="{Vendor}_{Module}::widget/{template_name}.phtml" selected="true">
                        <label translate="true">Default Template</label>
                    </option>
                </options>
            </parameter>
        </parameters>
        <containers>
            <container name="content">
                <template name="default" value="default"/>
            </container>
        </containers>
    </widget>
</widgets>
```

`<widget>` attributes:

| Attribute | Required | Meaning |
|-----------|----------|---------|
| `id` | yes | `xs:ID`, unique across the merged config of all modules → `{vendor_lower}_{module_lower}_{widget}` |
| `class` | yes | FQCN of the block; the admin form lists widgets by label but stores and looks them up by this class |
| `is_email_compatible` | no | `true` offers the widget in the email-template editor (JS-free, inline-styled output only). Default `false` |
| `placeholder_image` | no | `{Vendor}_{Module}::images/widget/{widget_id}.png` shown in the WYSIWYG editor; falls back to `Magento_Widget::placeholder.png` when absent or unreadable |
| `ttl` | no | Declared in the XSD, **ignored by the config converter** — control fragment caching with `cache_lifetime` instead |

Children: `<label>` (required, translatable — the name admins pick in the widget-type
dropdown), `<description>` (required), `<parameters>` (see `parameter-types.md`),
`<containers>` (optional; see the contract below).

## How a widget reaches the page — three entry points

### 1. Widget instance (Content → Widgets → Add Widget)

The admin picks the widget **type** (your label) and a design theme, then adds *Layout
Updates*: a page group, a **container** (offered from `<containers>`, or every layout
container when the element is omitted) and a **template** (the container's `<template>`
list). Magento stores the instance and, for each layout update, generates layout XML that
places the block and injects the saved parameters:

```xml
<referenceContainer name="content">
    <block class="{Vendor}\{Module}\Block\Widget\{WidgetName}" name="<random hash>"
           template="{Vendor}_{Module}::widget/{template_name}.phtml">
        <action method="setData">
            <argument name="name" xsi:type="string">title</argument>
            <argument name="value" xsi:type="string">Summer Sale</argument>
        </action>
        <action method="setData">
            <argument name="name" xsi:type="string">items_count</argument>
            <argument name="value" xsi:type="string">5</argument>
        </action>
    </block>
</referenceContainer>
```

Consequences: every parameter is a **string**; multiselect arrays are joined with `,`;
`conditions` is stored as `conditions_encoded`; parameters left blank are **not written at
all** (so `getData()` returns `null`). The generated XML is cached in the `layout` and
`full_page` caches.

### 2. Directive in CMS content (pages, blocks, emails)

```
{{widget type="{Vendor}\{Module}\Block\Widget\{WidgetName}" title="Summer Sale" items_count="5"
         template="{Vendor}_{Module}::widget/{template_name}.phtml"}}
```

The WYSIWYG editor's *Insert Widget* button writes exactly this (rendering the placeholder
image in the editor). At render time the widget filter looks the declaration up by class,
creates the block through the layout with `['data' => $params]`, returns an empty string
unless the block implements `BlockInterface`, and calls `toHtml()`. `Template::_construct()`
applies a `template` data key via `setTemplate()`, which is how the `template` parameter
overrides `$_template`.

### 3. Layout XML written by developers

```xml
<referenceContainer name="content">
    <block class="{Vendor}\{Module}\Block\Widget\{WidgetName}" name="{widget_id}.homepage"
           template="{Vendor}_{Module}::widget/{template_name}.phtml">
        <arguments>
            <argument name="title" xsi:type="string" translate="true">Summer Sale</argument>
            <argument name="items_count" xsi:type="string">5</argument>
        </arguments>
    </block>
</referenceContainer>
```

Arguments arrive as block data. This path can pass real arrays (`xsi:type="array"`) —
the one case where a multiselect accessor sees an array instead of a comma-joined string.

## The block

```php
class {WidgetName} extends Template implements BlockInterface
{
    public const DEFAULT_ITEMS_COUNT = 5;

    protected $_template = '{Vendor}_{Module}::widget/{template_name}.phtml';

    public function getTitle(): string { ... }      // trim((string) getData('title'))
    public function isShowTitle(): bool { ... }     // "1"/"0" → bool, absent → true
    public function getItemsCount(): int { ... }    // (int) with a positive guard → default

    public function getCacheKeyInfo(): array
    {
        return array_merge(parent::getCacheKeyInfo(), ['{widget_id}', $this->getTitle(), ...]);
    }
}
```

- `BlockInterface` only declares `addData()` / `setData()` — `Template` already provides
  them — so it is a **marker**, but the filter refuses to render without it.
- Typed accessors are the single place that knows parameters are strings and may be
  absent. The template and any collaborator call accessors only.
- **Data loading** is delegated: inject a service / repository / ViewModel, keep the block
  a thin adapter, and implement `Magento\Framework\DataObject\IdentityInterface` returning
  the rendered entities' cache tags when the widget shows persisted data.
- **Caching:** `AbstractBlock` caches a block's HTML only when `cache_lifetime` is set
  (`getCacheLifetime()` returns `null` otherwise). The scaffolded `getCacheKeyInfo()` is
  correct regardless, so enabling caching later (a `cache_lifetime` text parameter, a
  layout argument, `setData('cache_lifetime', 86400)` in `_construct()`) never merges two
  instances. Set `cache_tags` alongside when the content depends on entities.

## The `<containers>` ↔ `template` contract

`Instance::getWidgetSupportedTemplatesByContainer()` resolves each
`<container>/<template value="...">` against the **option names** of the `template`
select parameter. A `value` that matches no option name yields an empty template dropdown
for that container in the widget-instance form. Two valid designs:

- **Restricted:** declare `<containers>` for `content`, `sidebar.main`,
  `sidebar.additional` (the standard Luma/Hyvä containers) and keep every `value` equal
  to an option name. Add per-container variants (`grid` for content, `list` for sidebars)
  by adding options + templates in pairs.
- **Unrestricted:** omit `<containers>` — every container is offered, with every
  `template` option.

The `template` parameter is optional for widgets that never switch templates, but keep
it when `<containers>` exist.

## Email-compatible widgets

`is_email_compatible="true"` adds the widget to the *Insert Widget* dialog of the
email-template editor. Emails are rendered under store emulation with no JavaScript and
minimal CSS support, so such a widget emits table/anchor markup with inline styles and
builds URLs with `$block->getUrl()` (absolute). Pager, Alpine state, cart or customer
context all disqualify a widget from email use.

## Enablement and cache commands

```bash
# after adding Magento_Widget to <sequence> / composer.json
bin/magento setup:upgrade

# after any edit to etc/widget.xml, the block, or the template
bin/magento cache:clean config block_html full_page layout

# production mode only: templates are read from the deployed static-content / generated code
bin/magento setup:di:compile
```

## Validating widget.xml against the real schema

`xmllint --noout` proves well-formedness only; a misspelled attribute still passes. The
schema lives at `vendor/magento/module-widget/etc/widget.xsd` and includes `types.xsd`
through a `urn:magento:` URI that xmllint cannot resolve on its own — an XML catalog maps
it (absolute path required in the `file://` URI):

```bash
ROOT=/abs/path/to/magento   # {ctx.magento_root}
cat > /tmp/magento-widget-catalog.xml <<EOF
<?xml version="1.0"?>
<catalog xmlns="urn:oasis:names:tc:entity:xmlns:xml:catalog">
  <uri name="urn:magento:module:Magento_Widget:etc/types.xsd"
       uri="file://$ROOT/vendor/magento/module-widget/etc/types.xsd"/>
</catalog>
EOF
XML_CATALOG_FILES=/tmp/magento-widget-catalog.xml \
  xmllint --noout --schema "$ROOT/vendor/magento/module-widget/etc/widget.xsd" etc/widget.xml
```

Magento performs the same validation itself in developer mode when the config is read, so a
schema error also surfaces as an exception on the first admin page that lists widgets.

Where to look when something is off: `widget_instance` (saved instances and their
serialized parameters), `widget_instance_page` (page-group ↔ container bindings), and
`layout_update` (the generated XML from entry point 1).
