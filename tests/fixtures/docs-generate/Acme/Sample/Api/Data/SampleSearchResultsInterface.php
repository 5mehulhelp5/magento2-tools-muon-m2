<?php
declare(strict_types=1);
namespace Acme\Sample\Api\Data;

use Magento\Framework\Api\SearchCriteriaInterface;

/** @api */
interface SampleSearchResultsInterface
{
    /** @return SampleInterface[] */
    public function getItems(): array;

    public function getTotalCount(): int;

    public function getSearchCriteria(): SearchCriteriaInterface;
}
