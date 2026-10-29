# Version-bound reviews

A native review means satisfaction with a specific Markdown source version. It grants no execution authority or permissions. An agent response remains an agent response attributed to its human principal; it is never a human sign-off.

## Content and decision identity

Responses retain `plan_version_id`, that version’s SHA-256, `request_generation`, and a server-assigned `decision_sequence`. UUIDs identify transport retries; they do not order decisions. A request’s `current_response_id` is the authoritative projection. A response is effective only when it belongs to that request, generation and current plan version and matches the task status. `effective_human_decision` is null for pending, withdrawn, dismissed or agent decisions. `latest_approval` is positive history for comparison, not qualification.

The approval covers **Markdown source bytes only**. Title, tags, attachments, linked and embedded resources, child plans, and rendered output are excluded. URLs and embedded source syntax are approved as literal text, not as the bytes they might display. Historical pages expose exact source and hash and label the current title as metadata. Full rich-page approval requires a separate immutable asset envelope and renderer contract.

## Edits and cycles

All current-version writers use `Plans::AdvanceVersion`: Create, ReplaceContent (including SaveHumanDraft/web saves), CommitSession, ToggleCheckbox and the direct operations API. They already hold the plan row lock; CommitSession retains session-before-plan lock order. The version pointer, revision, review sequence, active task resets, generation increments and cleared current pointers commit together. Withdrawn tasks and all receipts remain intact. Resets broadcast after commit without sending a review-request notification for every edit.

An identical normalized ReplaceContent save creates no version and preserves approval. An empty session creates no version. A nonempty session or operations commit creates a new version even if its operations net to identical bytes, and dismisses decisions. Returning A→B→A always produces a distinct version and requires fresh review. Existing edit leases, human-edit fences and merge guards remain in place.

An explicit re-request advances the task generation and clears its effective decision. Creating an already existing request is a retry and leaves its state alone. Withdrawal clears the effective decision and preserves receipts. A fresh response supersedes the previous effective response, including a later agent response. The latest sequenced human response on the current version is exposed separately so consumers can inspect human feedback across request cycles; native CoPlan does not impose an external approval or objection policy.

New responses send the viewed revision, fetched generation and a fresh UUID `idempotency_key`. Stale revisions or generations fail with 409. Repeating a recorded key returns its immutable receipt without touching status, current pointer, sequence, attribution or notifications, even after an edit, withdrawal or re-request. Unkeyed identical legacy retries return history too. First-cycle clients may omit generation; subsequent cycles require it, including first-seen delayed keyed submissions. A fresh intentional identical response needs a new key and the current generation.

## Reads and compatibility

`GET /api/v1/plans/:id/review_evidence` takes one plan-row transaction and returns exact current source/hash/version, scope, review sequence, current projection and complete response history. It creates no PlanRead or agent session. Ordinary authentication may still update token usage. The review sequence covers body and native review changes, not excluded metadata, sharing or external authorization. Existing snapshot reads retain their older behavior; consumers requiring coherent evidence use this endpoint.

`GET /api/v1/plans/:id/versions/:version_id` returns that exact historical Markdown and hash. It never substitutes the current version. Both endpoints use existing Bearer authentication and visibility rules; neither establishes a read-only workload credential or employee identity mapping.

Migration preserves old receipts with unknown generation/sequence. Existing active tasks become pending with `reset_reason=legacy_history`; withdrawn tasks stay withdrawn. Existing tasks enter generation 2 so first-seen old requests without a cycle cannot complete them. No timestamp or UUID ordering is used to invent legacy effective approvals. Hosts must install the engine migration and update clients to send generation. Downgrading drops the new projection but does not restore prior statuses.

Persisted version IDs, plan IDs, revisions, Markdown and hashes reject ordinary Rails mutation, including `update_columns`. Writing provenance backfills remain supported. Hashes are checked at creation and before new responses or source evidence reads. These are application guarantees, not database/WORM protection against administrator SQL, bulk writes or deletion.

## Local tryout

Seed the shared demo library with `bin/rails coplan:demo:seed`. Sign in as `alex@example.com` and open **Workspace invitations: review dismissed after edits** in Hampton’s Demo scenarios. v1 approvals are history, v2 is pending, and the activity link opens the original source. Approve v2, then sign in as `hampton@example.com` and edit its body or toggle its checkbox. Alex’s task returns to pending. Re-seeding preserves edits and decisions.
