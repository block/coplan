Search p95 sits at 840 ms while p50 is fine — the tail is repeat fan-out, not slow ranking.[^p95-baseline] This design layers a request-local memo over a shared Redis tier to pull p95 under 300 ms without serving stale facets, and writes down the invalidation rules reviewers keep asking about (see [§3](#section-3)).

## 1. Problem

Every keystroke fans out to the ranking service, and most of that work repeats: two people typing "refund policy" build the same candidate set twice. The ranking call dominates the tail — [§4](#section-4) covers how the rollout measures it.

## 2. Two tiers, one interface

A request-local memo catches repeats within one search session; the shared Redis tier catches repeats across users. Eviction on the shared tier follows an allkeys-lru policy.[^redis-eviction]

```ruby
class CacheStack
  def initialize(local:, shared:)
    @tiers = [ local, shared ]
  end

  def fetch(key, &compute)
    @tiers.each_with_index do |tier, index|
      value = tier.read(key)
      next unless value
      promote(key, value, upto: index)
      return value
    end
    compute.call.tap { |value| write_through(key, value) }
  end
end
```

## 3. Invalidation

Facet counts may lag content by at most one minute. Writes publish a version stamp; a cached entry older than the stamp for any document in its candidate set is treated as a miss. There is no per-key TTL tuning — the stamp is the whole strategy.

## 4. Rollout

Dark-read first: serve uncached results while comparing them with cached results in the background, then ramp by query class once the comparison disagrees on fewer than 1 in 10,000 queries — the bar the invalidation rules in [§3](#section-3) were written to clear.

[^p95-baseline]: [Q2 search latency review](https://observability.example.com/d/search-latency) — trailing 30 days: p95 840 ms, p50 118 ms, with fan-out retries accounting for 62% of tail samples.
[^redis-eviction]: [Redis key eviction](https://redis.io/docs/latest/develop/reference/eviction/) — `allkeys-lru` approximates LRU across the whole keyspace, which fits a cache-only tier.
