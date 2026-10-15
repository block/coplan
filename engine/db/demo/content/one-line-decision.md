Use UUIDv7 for new public identifiers so clients can generate IDs offline and database inserts remain roughly ordered. Existing UUIDs remain valid; no backfill is required.
