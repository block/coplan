## Delivery proposal

Deliver each event at least once and preserve its identifier across retries. Consumers use the identifier to handle repeated deliveries safely.

## Retry policy

Retry transient failures with exponential backoff. Keep failed events available for inspection and replay.
