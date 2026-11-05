# Document titles

A plan's opening top-level H1 is its name. `Plan.title` is a plain-text projection for listings, search, and API responses. Rename a plan by editing its content. Legacy API `title` inputs are accepted and ignored.

All content commit paths normalize the opening heading before computing the version hash and provenance. An agent update without a usable opening H1 restores the current name. Creation defaults to `Untitled`. Code fences, quotes, and presentation regions do not supply the document title. Repairs are included in the version's positional operations so concurrent edits and comment anchors see the actual committed content.

The rich editor protects the first H1's structure. Its text can be erased and autosaved while typing; Done fills an empty title with `Untitled`. Human autosaves update the metadata and search without changing the URL. Done finalizes the URL, including when there is no new content to save. Agent commits finalize it immediately. Earlier exact aliases point directly to the latest address.

## Deployment and backfill

The engine migration `UnifyDocumentTitles` widens the metadata title to text and backfills each current plan in a locked transaction. Hosts install it with `bin/rails co_plan:install:migrations`, then run `bin/rails db:migrate`.

For existing documents, the saved metadata wins: a matching opening heading is retained, a different heading is replaced, and a missing heading is prepended. Historical versions are never edited. Changed documents receive a system version with replayable operations and updated anchor positions. Custom templates also receive an opening H1 when missing.

Run the migration with old writers stopped and active edit leases drained. An active lease stops the migration rather than writing over an agent session. The backfill is idempotent: after the lease expires or is released, rerun `db:migrate`; completed documents are skipped. The migration is irreversible because its versions are part of the audit history. Take the normal database backup before deployment.

Permanent write normalization differs from backfill: once deployed, a submitted opening H1 wins over metadata. The saved metadata is only a fallback when an agent omits or clears the heading.
