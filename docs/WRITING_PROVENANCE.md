# Writing provenance rollout

Install the engine migrations into a consuming host before deployment:

```sh
bin/rails co_plan:install:migrations
```

Deploy with the normal `db:prepare` or `db:migrate` step and running background workers. The example host already runs `db:prepare` from its Docker entrypoint. No manual per-document reconstruction or maintenance window for replaying history is required.

The schema migrations add version snapshots, the cached document summary, and a nullable document backfill-state column. The rollout migration captures each existing document's current revision as its historical cutoff. It records requests without loading document content or accessing the queue database. Startup and the migration tasks automatically start the coordinator once the schema is available. Asset builds using `SECRET_KEY_BASE_DUMMY` do not access the database for this feature.

## Historical attribution

Editor additions through that cutoff are assumed human-written. This is a one-time product assumption: old versions did not record typing versus paste. Uninstrumented editor versions from old instances during a rolling deployment use the same assumption, including new plans created after the migration scan. A marker on each rebuilt historical snapshot preserves that assumption on later reconstruction without moving the cutoff across interleaved new writes. Retained text from an agent keeps its AI source when a human changes another part of the document. Existing explicitly simulated demo agent/unknown identities are preserved. Instrumented editor versions always store a snapshot and use recorded typing and paste evidence; missing input evidence remains Unknown. New documents have no historical cutoff.

Reconstruction changes attribution metadata only. It does not change document text, create content revisions, or change who made an edit.

## Background work and recovery

`CoPlan::WritingProvenanceBackfillJob` scans 100 document records at a time without loading version content. `CoPlan::WritingProvenanceJob` works for up to 20 versions or three seconds before yielding. Each processed version commits a durable revision checkpoint.

A database-backed claim prevents separate workers from claiming the same document for five minutes; each committed checkpoint renews it. Computation occurs outside the document lock. A worker must still own the claim and checkpoint before saving its result. Older workers cannot overwrite a replacement worker's progress. A separate finalized revision advances only when the current summary is published, so a crash after the last version checkpoint still leaves recoverable work.

The coordinator revisits pending documents after the lease horizon, recovering a worker that died before scheduling its continuation. Jobs also retry transient failures. Both jobs use priority 20 so normal work with default priority can run first. Startup, document claims, and progress do not depend on the cache database. Multiple boot scans can run safely: only one can claim a particular document.

Watch the normal job failure/retry dashboard and the pending document count. In a Rails console:

```ruby
CoPlan::Plan.find_each.count { |plan| CoPlan::Plans::WritingProvenanceBackfill.pending?(plan) }
```

A restart scans pending work again; it does not erase checkpoints or move the historical cutoff. A completed document advances its checkpoint with normal subsequent saves.

## Reading and inspection

Normal document navigation reads the cached summary and never reconstructs history. Percentages remain available independently of inspection.

Inspection mappings are cached for 12 hours by version and a digest of its provenance. Rebuilding attribution invalidates that cache even when document text is unchanged. Inspection is limited to 250,000 source characters, 10,000 attribution runs, and 10,000 browser highlight ranges. Above those limits, the popover explains that inspection is unavailable while percentages remain usable. API source ranges are still available.

For new edits, the diff budget still falls toward Unknown when a replacement cannot be matched within its bounded processing cost. Historical editor replacements use the rollout's human-written assumption instead. Source snapshots grow with retained attribution boundaries and are stored per version; monitor database size alongside save latency as histories grow.
