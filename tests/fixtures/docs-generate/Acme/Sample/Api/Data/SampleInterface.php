<?php
declare(strict_types=1);
namespace Acme\Sample\Api\Data;

/** @api */
interface SampleInterface
{
    public function getEntityId(): int;
    public function getCustomerEmail(): string;
    public function isActive(): bool;

    /** A getter whose type lives outside this module — the example walker cannot
     *  resolve it and must degrade the field to a "string" placeholder. */
    public function getStore(): \Magento\Store\Api\Data\StoreInterface;

    /**
     * A bare `array` annotation: Magento's own TypeProcessor rejects it, which takes
     * the whole /rest/<store>/schema endpoint down store-wide. The extractor must
     * report it as a warning without failing the run.
     *
     * @param array $context
     */
    public function setContext(array $context): void;
}
