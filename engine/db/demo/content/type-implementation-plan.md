## Phase 1: receipt foundation

Alex adds the unique request-key constraint and the receipt lookup. Exit when repeated requests return the same receipt under concurrent load.

## Phase 2: retry-safe delivery

Hampton connects the delivery adapter to the receipt. Aiko adds queue-age monitoring. Exit when a simulated network failure produces a retry and no extra invitation.

## Phase 3: acceptance on every screen

Mateo checks offline recovery and narrow layouts. Noura checks expiration and role boundaries. Exit when each acceptance case creates exactly one membership.

## Phase 4: beta rollout

Enable twelve teams, observe delivery latency, and collect administrator feedback before expanding. Keep the rollback limited to new invitation creation; existing receipts remain readable.

## Checklist

- [ ] Receipt constraint and concurrency checks
- [ ] Adapter failure and retry checks
- [ ] Desktop, mobile, and keyboard acceptance checks
- [ ] Beta dashboard and rollback instructions
