Checkout got slower after the March pricing release. The p95 for `POST /checkout` went from 420 ms to 610 ms. Almost all of the extra time is spent loading discount rules for each line item. Caching the rules per cart brings the p95 back to 430 ms in staging. We plan to ship the cache behind a flag next week.

The evidence and the options we rejected are in the collapsed sections below. Each closed section shows how many open discussions it hides. Select the count to open the section at its first discussion, or press j to step through every discussion, hidden or not.

## Findings

Slow carts are large carts. Carts with more than 20 line items account for most of the regression, and small carts are unchanged.

<details>
<summary>Raw measurements</summary>

We sampled 50,000 checkout requests from the week before and the week after the release.

| Cart size | p95 before | p95 after |
| --- | --- | --- |
| 1–5 items | 380 ms | 390 ms |
| 6–20 items | 450 ms | 520 ms |
| 21+ items | 690 ms | 1,240 ms |

Each line item runs one discount rule query, so a 40-item cart makes 40 round trips to the pricing database.

<details>
<summary>Query plan</summary>

The rule lookup uses the merchant index but filters item categories in memory, so every query reads all of a merchant's active rules.

</details>

Weekend traffic was excluded because a marketing campaign doubled cart sizes on those days.

</details>

## Options

We compared three ways to remove the repeated lookups.

<details>
<summary>Alternatives considered</summary>

Batching the queries into one request per cart halves the time but still grows with merchant rule count.

Precomputing prices nightly removes the lookups, but price changes would take up to a day to appear.

</details>

## Plan

Cache each merchant's active rules for the life of one cart request. Invalidate the cache when a merchant edits a rule. Roll out to 10% of merchants first and compare p95 by cart size.
