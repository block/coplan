## Compatibility boundary

The next pricing API accepts a rule version on each request. Requests without a version use the merchant's active configuration; receipts always record the resolved version.

## Migration

1. Persist the resolved version alongside the receipt.
2. Add shadow comparisons for the new evaluator.
3. Enable versioned requests for internal clients.
4. Publish the versioned contract after mismatch rates stabilize.
