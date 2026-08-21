<?php
declare(strict_types=1);
namespace Acme\Sample\Api;

use Acme\Sample\Api\Data\SampleInterface;
use Acme\Sample\Api\Data\SampleSearchResultsInterface;
use Magento\Framework\Api\SearchCriteriaInterface;
use Magento\Framework\Exception\NoSuchEntityException;

/** @api */
interface SampleRepositoryInterface
{
    /**
     * @throws NoSuchEntityException
     */
    public function getById(int $id): SampleInterface;

    public function save(SampleInterface $sample): SampleInterface;

    /** PHP 8 union types — request_shape must resolve the DTO, not degrade to "string". */
    public function upsert(SampleInterface|null $sample): SampleInterface|null;

    /**
     * The SearchCriteria parameter is out-of-module, so the walker cannot type it —
     * the route is flagged `is_search_criteria` and gets the shared query parameters.
     */
    public function getList(SearchCriteriaInterface $searchCriteria): SampleSearchResultsInterface;

    /** Reachable only from the `self` (customer-token) route. */
    public function getForCurrentCustomer(): SampleInterface;
}
