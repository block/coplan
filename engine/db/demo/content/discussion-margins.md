## Several discussions on one line

Review receipt, delivery, retry, timeout, and rollback together.

Each word above starts a separate discussion. The receipt discussion has replies from Hampton and Noura. In the margin, its avatar still identifies Alex, who started it. Nearby markers stack downward; hover a marker to see its exact passage.

This resolved example is hidden until Show resolved is enabled. Open and resolved describe discussion lifecycle. These avatars do not indicate unread activity.

## Discussions inside slides

Use Next slide and Previous slide. Each slide has its own discussion. On the second slide, scroll inside the slide and watch its marker follow the passage.

::: {.presentation}

# First slide

The first slide discussion covers the rollout decision.

---

# Second slide

The second slide discussion covers operational readiness.

## Rollout checklist

- Confirm the cohort has a named owner.
- Verify the tenant boundary in the receipt key.
- Check duplicate delivery metrics before expansion.
- Exercise a timed-out request and its retry.
- Confirm the receipt survives a worker restart.
- Verify the retry budget under partial failure.
- Trace the delivery attempt to the original request.
- Test the alert route with the on-call responder.
- Record the expected recovery time.
- Confirm rollback preserves existing receipts.
- Check the mobile client's error message.
- Validate the audit trail after rollback.
- Review the retention period with security.
- Check that expired receipts cannot be replayed.
- Document the support escalation path.
- Compare the cohort's latency with the control.
- Inspect the queue after a burst of retries.
- Confirm the fallback does not bypass authorization.
- Record the launch decision in the readout.
- Assign the follow-up measurement to an owner.

:::
