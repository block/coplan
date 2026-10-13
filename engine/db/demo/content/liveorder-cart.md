## State ownership

The cart owns item selection and prices. Checkout owns submission and confirmation. A durable idempotency key joins the two without allowing either service to silently replay a charge.

## Transitions

| Current state | Event | Next state |
| --- | --- | --- |
| Editing | Submit | Submitting |
| Submitting | Confirmation receipt | Confirmed |
| Submitting | Network timeout | Awaiting receipt |
| Awaiting receipt | Receipt recovered | Confirmed |

## Failure behavior

A timeout is an unknown result. Recover the receipt before offering another submission.
