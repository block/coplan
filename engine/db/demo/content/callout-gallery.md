> [!IMPORTANT] Decision needed
> Choose the retention window by Friday. The rest of the plan is ready: archived invoices move to cold storage in three batches over two weeks, and customers see no change.

## Background

Archived invoices make up most of the primary database, but fewer than one read in a thousand touches them. Moving them frees space and shortens backups.

> [!NOTE]
> An invoice is archived ninety days after it is paid. Open and disputed invoices never move.

## Plan

1. Copy one batch to cold storage.
2. Compare row counts and checksums.
3. Switch reads for that batch, then delete it from the primary database.

> [!TIP]
> Run the copy with `--dry-run` first. It prints the batch size and the expected run time without writing anything.

> [!WARNING]
> Each batch holds a lock on the archive table for up to a minute. Schedule batches outside the evening billing run:
>
> - Batch 1: Tuesday, 02:00 UTC
> - Batch 2: Thursday, 02:00 UTC
> - Batch 3: the following Tuesday, 02:00 UTC
>
> ```sql
> SELECT COUNT(*) FROM invoices WHERE archived_at < NOW() - INTERVAL 90 DAY;
> ```

> [!CAUTION]
> Deleting a batch from the primary database cannot be undone. Do not delete a batch until its checksums match.

## Comparison

A plain blockquote stays a quote:

> Storage is cheap; the backup window is not.

An unknown marker also stays a plain blockquote:

> [!QUESTION]
> Should finance review the retention window?

An escaped known marker stays literal too:

> \[!NOTE]
> This text explains the syntax rather than creating a note.

## Callouts in slides

The deck palette stays fixed when the app switches between light and dark mode.

::: {.presentation theme="coplan"}

# Retention rollout

> [!TIP]
> Compare checksums before deleting the original batch.

:::

::: {.presentation theme="graphite"}

# Retention rollout

> [!WARNING]
> Schedule the archive lock outside the billing run.

:::
