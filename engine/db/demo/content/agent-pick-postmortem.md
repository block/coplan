## What happened

A cache flush made every checkout request fetch the same merchant configuration. The database connection pool filled before autoscaling added capacity.

## Contributing factors

- Cache entries expired at the same boundary.
- Retries had no jitter.
- The fallback path had no concurrency budget.

## Follow-up

Add single-flight loading, jitter expiration, and cap fallback concurrency. Prove recovery with a cache-loss exercise before closing the incident.
