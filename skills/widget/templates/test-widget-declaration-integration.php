<?php

declare(strict_types=1);

namespace {Vendor}\{Module}\Test\Integration\Widget;

use Magento\Framework\View\LayoutInterface;
use Magento\TestFramework\Fixture\AppArea;
use Magento\TestFramework\Helper\Bootstrap;
use Magento\Widget\Model\Config\Data as WidgetConfig;
use PHPUnit\Framework\TestCase;
use {Vendor}\{Module}\Block\Widget\{WidgetName};

/**
 * Integration test for the {WidgetName} declaration.
 *
 * Covers what the unit test cannot: that etc/widget.xml is merged into the widget config
 * with the right block class and parameters, and that the block renders through its
 * template in the frontend area. Runs under dev/tests/integration; the #[AppArea]
 * attribute needs Magento 2.4.5+ (use the `@magentoAppArea frontend` annotation before that).
 *
 * Target: {Vendor}/{Module}/Test/Integration/Widget/{WidgetName}DeclarationTest.php
 */
#[AppArea('frontend')]
class {WidgetName}DeclarationTest extends TestCase
{
    /**
     * Skip — with the exact reason, never silently — when the integration framework is absent
     * (unit-only runs, no dev/tests/integration bootstrap). Delete this guard once the suite
     * runs under the integration framework only.
     */
    protected function setUp(): void
    {
        if (!class_exists(Bootstrap::class)) {
            self::markTestSkipped(
                'Magento integration test framework is not loaded — run from dev/tests/integration'
            );
        }
    }

    /**
     * The merged widget config must list "{widget_id}" with the block FQCN and every parameter.
     */
    public function testWidgetIsDeclaredWithItsBlockAndParameters(): void
    {
        $widgets = Bootstrap::getObjectManager()->get(WidgetConfig::class)->get();

        self::assertArrayHasKey(
            '{widget_id}',
            $widgets,
            'etc/widget.xml is not merged — check the widget id and clean the config cache'
        );

        $widget = $widgets['{widget_id}'];
        self::assertSame({WidgetName}::class, $widget['@']['type']);
        self::assertSame('{WidgetLabel}', $widget['name']);
        foreach (['title', 'show_title', 'items_count', 'template'] as $parameter) {
            self::assertArrayHasKey(
                $parameter,
                $widget['parameters'],
                sprintf('parameter "%s" is missing from widget.xml', $parameter)
            );
        }
    }

    /**
     * A block created the way the widget filter creates it must render the title through
     * the template — proving the template path, the escaper wiring and the accessor chain.
     */
    public function testBlockRendersTheTitleThroughTheTemplate(): void
    {
        $layout = Bootstrap::getObjectManager()->get(LayoutInterface::class);
        $block = $layout->createBlock(
            {WidgetName}::class,
            '',
            ['data' => ['title' => 'Smoke Test Title', 'items_count' => '2']]
        );

        $html = $block->toHtml();

        self::assertStringContainsString('Smoke Test Title', $html);
        self::assertStringContainsString('widget-{widget_id}', $html);
    }
}
