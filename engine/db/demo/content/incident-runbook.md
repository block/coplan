## Symptoms

Checkout requests are timing out while payment authorization remains healthy. The dashboard shows p95 above 800 ms for three consecutive minutes.

## First five minutes

1. Compare checkout latency with authorization latency.
2. Check connection-pool saturation and the last deployment.
3. Pause the rollout if errors exceed 1%.
4. Assign one incident lead and one person to customer updates.

## Recovery

Prefer reducing concurrency before adding retries. Retries amplify a saturated dependency. Roll back the newest deployment if the error rate follows the deployment boundary.

## Verification

- [ ] p95 stays below 400 ms for ten minutes.
- [ ] Duplicate authorizations remain at zero.
- [ ] The incident timeline includes the recovery decision.

## References

[Google SRE: Managing incidents](https://sre.google/sre-book/managing-incidents/) explains the incident roles used here.
