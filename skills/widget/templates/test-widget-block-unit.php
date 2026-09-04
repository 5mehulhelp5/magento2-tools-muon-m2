<?php

declare(strict_types=1);

namespace {Vendor}\{Module}\Test\Unit\Block\Widget;

use Magento\Framework\App\State;
use Magento\Framework\UrlInterface;
use Magento\Framework\View\Element\Template\Context;
use Magento\Framework\View\Element\Template\File\Resolver;
use Magento\Store\Api\Data\StoreInterface;
use Magento\Store\Model\StoreManagerInterface;
use Magento\Widget\Block\BlockInterface;
use PHPUnit\Framework\TestCase;
use {Vendor}\{Module}\Block\Widget\{WidgetName};

/**
 * Unit test for {WidgetName}.
 *
 * Pins the parameter contract: defaults when a parameter is absent, coercion of the string
 * values widgets deliver, and a cache key that varies with the parameters. Built on a
 * mocked Template\Context — no Magento bootstrap required.
 *
 * Target: {Vendor}/{Module}/Test/Unit/Block/Widget/{WidgetName}Test.php
 */
class {WidgetName}Test extends TestCase
{
    /**
     * Absent parameters must resolve to the documented defaults, never to null/false/0.
     */
    public function testAccessorsFallBackToDefaultsWhenParametersAreAbsent(): void
    {
        $block = $this->createBlock();

        self::assertSame('', $block->getTitle());
        self::assertSame({WidgetName}::DEFAULT_ITEMS_COUNT, $block->getItemsCount());
        self::assertTrue($block->isShowTitle());
    }

    /**
     * Widget instances and directives deliver strings: "12" must become 12, "0" false, "1" true.
     */
    public function testAccessorsCoerceTheStringValuesWidgetsDeliver(): void
    {
        $block = $this->createBlock([
            'title' => '  Summer Sale ',
            'items_count' => '12',
            'show_title' => '0',
        ]);

        self::assertSame('Summer Sale', $block->getTitle());
        self::assertSame(12, $block->getItemsCount());
        self::assertFalse($block->isShowTitle());
        self::assertTrue($this->createBlock(['show_title' => '1'])->isShowTitle());
    }

    /**
     * Non-positive or non-numeric counts fall back to the default instead of rendering nothing.
     */
    public function testInvalidItemsCountFallsBackToTheDefault(): void
    {
        foreach (['0', '-3', 'abc', ''] as $invalid) {
            self::assertSame(
                {WidgetName}::DEFAULT_ITEMS_COUNT,
                $this->createBlock(['items_count' => $invalid])->getItemsCount(),
                sprintf('items_count "%s" must fall back to the default', $invalid)
            );
        }
    }

    /**
     * The cache key must carry every parameter value on top of the Template defaults.
     */
    public function testCacheKeyInfoContainsEveryParameter(): void
    {
        $block = $this->createBlock([
            'title' => 'Summer Sale',
            'items_count' => '3',
            'show_title' => '1',
        ]);

        // Assert the appended tail exactly, not `assertContains(3, ...)` / `assertContains(1, ...)`:
        // a bare scalar could also be contributed by parent::getCacheKeyInfo(), so a containment
        // check can pass while the parameter was never appended at all. Pinning the segment also
        // pins its order and its types (the bool arrives as int 1, not "1" or true).
        $appended = array_slice(array_values($block->getCacheKeyInfo()), -4);

        self::assertSame(['{widget_id}', 'Summer Sale', 3, 1], $appended);
    }

    /**
     * Identical parameters → identical key; different parameters → different key. This is
     * the guarantee that two widget instances never share one cached fragment.
     */
    public function testCacheKeyInfoVariesWithParameters(): void
    {
        $sale = $this->createBlock(['title' => 'Summer Sale', 'items_count' => '3', 'show_title' => '1']);
        $sameSale = $this->createBlock(['title' => 'Summer Sale', 'items_count' => '3', 'show_title' => '1']);
        $clearance = $this->createBlock(['title' => 'Clearance', 'items_count' => '3', 'show_title' => '1']);
        $shorterSale = $this->createBlock(['title' => 'Summer Sale', 'items_count' => '2', 'show_title' => '1']);
        $untitledSale = $this->createBlock(['title' => 'Summer Sale', 'items_count' => '3', 'show_title' => '0']);

        self::assertSame($sale->getCacheKeyInfo(), $sameSale->getCacheKeyInfo());
        self::assertNotSame($sale->getCacheKeyInfo(), $clearance->getCacheKeyInfo());
        self::assertNotSame($sale->getCacheKeyInfo(), $shorterSale->getCacheKeyInfo());
        self::assertNotSame($sale->getCacheKeyInfo(), $untitledSale->getCacheKeyInfo());
    }

    /**
     * The widget filter renders only blocks that carry the marker interface; removing
     * `implements BlockInterface` makes the widget render as an empty string with no error.
     */
    public function testIsRecognisedAsAWidgetBlock(): void
    {
        self::assertInstanceOf(BlockInterface::class, $this->createBlock());
    }

    /**
     * Build the block with a mocked context. Template::getCacheKeyInfo() touches the store
     * manager, the template resolver, the app state (area) and the URL builder, so exactly
     * those four context getters return configured mocks; everything else may stay null.
     *
     * @param array $data Widget parameters as the framework delivers them (name => string value)
     * @return {WidgetName}
     */
    private function createBlock(array $data = []): {WidgetName}
    {
        // Only getCode() matters: parent::getCacheKeyInfo() keys on the store CODE, never its id.
        $store = $this->createMock(StoreInterface::class);
        $store->method('getCode')->willReturn('default');

        $storeManager = $this->createMock(StoreManagerInterface::class);
        $storeManager->method('getStore')->willReturn($store);

        $resolver = $this->createMock(Resolver::class);
        $resolver->method('getTemplateFileName')
            ->willReturn('app/code/{Vendor}/{Module}/view/frontend/templates/widget/{template_name}.phtml');

        $appState = $this->createMock(State::class);
        $appState->method('getAreaCode')->willReturn('frontend');

        $urlBuilder = $this->createMock(UrlInterface::class);
        $urlBuilder->method('getBaseUrl')->willReturn('https://example.com/');

        $context = $this->createMock(Context::class);
        $context->method('getStoreManager')->willReturn($storeManager);
        $context->method('getResolver')->willReturn($resolver);
        $context->method('getAppState')->willReturn($appState);
        $context->method('getUrlBuilder')->willReturn($urlBuilder);

        return new {WidgetName}($context, $data);
    }
}
