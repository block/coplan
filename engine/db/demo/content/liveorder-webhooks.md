## Delivery contract

Fulfillment consumers receive an at-least-once event stream. The event ID is stable across retries, and consumers store it with their domain update in the same transaction.

```json
{
  "event_id": "evt_demo_001",
  "type": "order.fulfilled",
  "order_id": "ord_demo_042",
  "version": 3
}
```

## Retry policy

Retry with exponential backoff for 24 hours. After that window, move the event to the dead-letter queue and surface a recovery task. Never treat a 2xx response as proof that downstream fulfillment completed.
