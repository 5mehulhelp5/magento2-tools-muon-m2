# SearchCriteria Query Parameters

Every Magento `getList`-style REST route takes a single
`Magento\Framework\Api\SearchCriteriaInterface` parameter. The DTO walker in
`scripts/extract-surface.sh` resolves types **module-locally** (see
`references/surface-extraction.md`, surface 14, step 2), so that parameter falls
outside the module and degrades to `"string"` — a body parameter that does not exist.

Widening the walker to reach into `Magento\Framework` is not the fix: it would drag the
entire framework type graph into every extraction. Instead the extractor sets
`is_search_criteria: true` on the route (detected by matching the **resolved parameter
FQCN** against `*\Api\SearchCriteriaInterface` — `getList` is a naming convention, not a
guarantee), and the emitter substitutes the fixed, hand-written parameter set below.

The set is `$ref`-ed once into `components/parameters` rather than repeated per
operation, so a spec with twenty `getList` routes carries one copy.

## The canonical set

`scripts/emit-api-artifacts.sh` holds these in `SEARCH_CRITERIA_PARAMS` and is the
single source of truth for their descriptions and types.
`tests/test-docs-generate-searchcriteria.sh` asserts that this file and that list name
exactly the same parameters, so the two cannot drift.

| Component name | Query parameter | Type |
|----------------|-----------------|------|
| `searchCriteriaFilterField` | `searchCriteria[filterGroups][0][filters][0][field]` | string |
| `searchCriteriaFilterValue` | `searchCriteria[filterGroups][0][filters][0][value]` | string |
| `searchCriteriaFilterConditionType` | `searchCriteria[filterGroups][0][filters][0][conditionType]` | string |
| `searchCriteriaSortField` | `searchCriteria[sortOrders][0][field]` | string |
| `searchCriteriaSortDirection` | `searchCriteria[sortOrders][0][direction]` | string |
| `searchCriteriaPageSize` | `searchCriteria[pageSize]` | integer |
| `searchCriteriaCurrentPage` | `searchCriteria[currentPage]` | integer |

The machine-readable form the drift test parses — one component name per line:

```search-criteria-params
searchCriteriaFilterField
searchCriteriaFilterValue
searchCriteriaFilterConditionType
searchCriteriaSortField
searchCriteriaSortDirection
searchCriteriaPageSize
searchCriteriaCurrentPage
```

## Semantics

- **Filter groups are AND-ed; filters inside one group are OR-ed.** The `[0]` indices are
  the first group and the first filter in it; a client adds `[1]`, `[2]`, … as needed.
  The generated spec describes index `0` only — enumerating an unbounded index space
  would be inventing endpoints, not describing them.
- **`conditionType`** accepts `eq`, `neq`, `like`, `nlike`, `in`, `nin`, `gt`, `lt`,
  `gteq`, `lteq`, `null`, `notnull`, `from`, `to`. With `like`, `%` is the wildcard and
  must be supplied by the caller.
- **`direction`** is `ASC` or `DESC`.
- **`pageSize` / `currentPage`** are integers; `currentPage` is 1-based.

## What is deliberately not emitted

- No `searchCriteria[filterGroups][n]` for `n > 0` — see above.
- No per-field `enum` for `field`. The set of filterable fields is a property of the
  collection's backing table, which this skill does not read at spec-generation time.
  Inventing one would violate the never-invent-facts rule in `SKILL.md`.
