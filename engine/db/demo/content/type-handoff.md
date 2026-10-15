## What shipped

The invitation API writes a durable receipt and queues delivery. The email adapter retries transient errors using the same receipt.

## Operational owner

Aiko monitors delivery latency. Hampton owns the beta cohort and customer-facing copy. Alex owns the receipt constraint and rollback decision.

## If delivery slows down

Pause new cohort expansion, inspect queue age, and compare adapter errors with receipt creation rate. Do not resend invitations with new receipt IDs.

## Follow-up

- Publish the beta dashboard.
- Check expired invitation volume after one week.
- Hand over the weekly review to the reliability rotation.
