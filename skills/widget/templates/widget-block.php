<?php

declare(strict_types=1);

namespace {Vendor}\{Module}\Block\Widget;

use Magento\Framework\View\Element\Template;
use Magento\Widget\Block\BlockInterface;

/**
 * {WidgetLabel} widget block — declared in etc/widget.xml as "{widget_id}".
 *
 * Every widget parameter reaches this block as a STRING through setData(): from a widget
 * instance's generated layout update (Content → Widgets), from a widget directive in CMS
 * content, or from a layout XML <argument>. Blank parameters are dropped before they get
 * here, so getData() returns null for them. The typed accessors below own coercion and
 * defaults; the template reads only those, never raw getData().
 *
 * Keep this class free of business logic. A widget that loads data injects a service or
 * ViewModel and delegates to it, and implements
 * Magento\Framework\DataObject\IdentityInterface when it renders persisted entities.
 *
 * Target: {Vendor}/{Module}/Block/Widget/{WidgetName}.php
 */
class {WidgetName} extends Template implements BlockInterface
{
    /**
     * Runtime default for `items_count`; keep equal to the <value> in widget.xml.
     */
    public const DEFAULT_ITEMS_COUNT = 5;

    /**
     * Default template, fully qualified.
     *
     * The `{Vendor}_{Module}::` prefix makes the path resolve through theme overrides and
     * Hyvä compatibility modules regardless of which module a subclass lives in. The
     * `template` select parameter in widget.xml overrides it per instance.
     *
     * @var string
     */
    protected $_template = '{Vendor}_{Module}::widget/{template_name}.phtml';

    /**
     * Heading text entered by the admin; empty string when the parameter is absent.
     *
     * @return string
     */
    public function getTitle(): string
    {
        return trim((string) $this->getData('title'));
    }

    /**
     * Whether the heading is rendered. Yes/No selects deliver "1" / "0"; absent means yes.
     *
     * @return bool
     */
    public function isShowTitle(): bool
    {
        $value = $this->getData('show_title');
        if ($value === null || $value === '') {
            return true;
        }

        return filter_var($value, FILTER_VALIDATE_BOOLEAN);
    }

    /**
     * Maximum number of items to render.
     *
     * Non-numeric or non-positive input falls back to the default rather than rendering
     * nothing.
     *
     * @return int
     */
    public function getItemsCount(): int
    {
        $count = (int) $this->getData('items_count');

        return $count > 0 ? $count : self::DEFAULT_ITEMS_COUNT;
    }

    /**
     * Block-HTML cache key including every widget parameter.
     *
     * Template::getCacheKeyInfo() keys on store, template file and base URL only; without
     * the parameter values appended, two instances of this widget would share one cached
     * fragment as soon as cache_lifetime is set anywhere.
     *
     * @return array<int|string, mixed>
     */
    public function getCacheKeyInfo(): array
    {
        return array_merge(
            parent::getCacheKeyInfo(),
            [
                '{widget_id}',
                $this->getTitle(),
                $this->getItemsCount(),
                (int) $this->isShowTitle(),
            ]
        );
    }
}
