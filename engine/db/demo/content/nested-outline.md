This review walks a fictional order service through ten numbered areas, each with its own sub-sections. Use it to try the outline on a document taller than the screen: sections fold, the outline follows your reading position, and a folded section totals the open discussions inside it.

## 1. Scope

### 1.1 System under review

The order service accepts carts from web and mobile clients, prices them, reserves inventory, and hands paid orders to fulfillment.

### 1.2 Out of scope

Payment authorization and the warehouse systems are reviewed separately. This document treats them as external dependencies.

### 1.3 Method

Each area lists what can go wrong, how the service notices, and what limits the damage. Findings carry a severity and an owner.

## 2. Context

### 2.1 Users

Shoppers place orders, support agents amend them, and merchants configure catalog and pricing rules.

### 2.2 Dependencies

The service calls pricing, inventory, payments, and notifications. Each call has a timeout and a fallback described in section 6.

### 2.3 Traffic shape

Traffic peaks during evening hours and seasonal sales, at roughly eight times the overnight baseline.

### 2.4 Data held

Orders, order lines, reservation records, and an outbox of events for downstream consumers.

## 3. Architecture

### 3.1 Request path

A request passes the edge proxy, the order API, and a pricing call before the order is written in one transaction.

### 3.2 Storage

A primary database with two replicas holds orders. Replicas serve history pages only.

### 3.3 Asynchronous work

Fulfillment and notification events leave through a transactional outbox, drained by a worker pool.

### 3.4 Deployment

The service runs in three zones behind a regional load balancer, with rolling deploys and automatic rollback on error-rate alarms.

## 4. Correctness

### 4.1 Pricing consistency

The price shown at checkout must match the price charged. The order stores the quoted price and its quote identifier.

### 4.2 Duplicate submissions

A double tap or a client retry can submit the same cart twice. Each submission carries an idempotency key scoped to the cart.

Keys expire after twenty-four hours, which covers every retry policy in the clients.

### 4.3 Reservation drift

Inventory reservations can outlive abandoned checkouts. A sweeper releases reservations older than thirty minutes.

### 4.4 Partial failures

When payment succeeds but the order write fails, a reconciliation job matches captured payments to orders within five minutes.

## 5. Availability

### 5.1 Zone loss

Losing one zone removes a third of capacity. Autoscaling restores headroom within ten minutes.

### 5.2 Database failover

Failover promotes a replica in under a minute. Writes fail fast during the switch and clients retry with backoff.

### 5.3 Dependency outages

Pricing and inventory outages degrade checkout; notification outages do not block it.

### 5.4 Load shedding

At saturation the edge proxy sheds browse traffic before checkout traffic.

## 6. Dependencies

### 6.1 Timeouts

Every outbound call has a deadline shorter than the client's own, so the service can answer before the client gives up.

### 6.2 Retries

Retries use jittered backoff and a shared budget, so a slow dependency is not met with a retry storm.

### 6.3 Fallbacks

If pricing is unavailable, checkout pauses with a clear message rather than charging a stale price.

## 7. Security

### 7.1 Authentication

Shopper sessions use short-lived tokens. Support tools require single sign-on and a reason for every order change.

### 7.2 Authorization

Merchants can read only their own orders. Support access is logged and reviewed weekly.

### 7.3 Data protection

Addresses and phone numbers are encrypted at rest. Logs record order identifiers, never contact details.

### 7.4 Abuse

Rate limits apply per account and per device to slow card-testing attacks.

## 8. Observability

### 8.1 Metrics

Checkout success rate, latency percentiles, and outbox lag are on the service dashboard.

### 8.2 Logs

Structured logs carry a request identifier through every call, including the outbox worker.

### 8.3 Alerts

Alerts page on checkout success rate and outbox lag; other signals open tickets.

## 9. Operations

### 9.1 Runbooks

Each alert links to a runbook with diagnosis steps and safe mitigations.

### 9.2 On-call

A primary and secondary engineer cover the service around the clock, with a weekly handoff.

### 9.3 Change management

Schema changes ship behind a feature flag and are reversible for one release.

### 9.4 Game days

A quarterly exercise rehearses zone loss and database failover in a staging region.

## 10. Findings

### 10.1 Summary

Two findings are high severity, three are medium, and four are low.

### 10.2 High severity

Reconciliation runs every five minutes, which leaves a window where a charged shopper sees no order. Shorten the interval or show a pending state.

### 10.3 Medium severity

Replica lag is not alerted, so history pages can silently show stale orders.

### 10.4 Next steps

Owners confirm each finding within a week. The review is repeated after the next major release.
