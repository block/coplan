---
name: coplan
description: "Upload, edit, and comment on plans via the CoPlan API. Use when asked to create plans, edit plan documents, manage edit leases, or leave review comments on plans."
---

# CoPlan API

Interact with the CoPlan app to create, read, edit, and comment on plan documents.

## Setup

You need an API token. The base URL defaults to `http://localhost:3000`.

```bash
export PLANNING_API_TOKEN="your-token-here"
export PLANNING_BASE_URL="http://localhost:3000"
```

## API Reference

All requests use `Authorization: Bearer $PLANNING_API_TOKEN` header.

### List Plans

```bash
curl -s -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans" | jq .
```

Optional query param: `?status=considering`

### Get Plan

```bash
curl -s -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID" | jq .
```

Returns: `id`, `title`, `status`, `current_content` (markdown), `current_revision`.

### Create Plan

```bash
curl -s -X POST \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title": "My Plan", "content": "# My Plan\n\nContent here."}' \
  "$PLANNING_BASE_URL/api/v1/plans" | jq .
```

### Update Plan

Update plan metadata (title, status, tags). Only fields included in the request body are changed.

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "considering"}' \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID" | jq .
```

Allowed fields: `title` (string), `status` (string — one of `brainstorm`, `considering`, `developing`, `live`, `abandoned`), `tags` (array of strings).

### Get Versions

```bash
curl -s -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/versions" | jq .
```

### Get Comments

```bash
curl -s -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/comments" | jq .
```

## Editing Plans (Lease + Operations)

Editing requires three steps: acquire lease → apply operations → release lease.

### 1. Acquire Edit Lease

```bash
LEASE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"lease_token": "'$(openssl rand -hex 32)'"}' \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/lease")
echo "$LEASE_RESPONSE" | jq .
LEASE_TOKEN=$(echo "$LEASE_RESPONSE" | jq -r '.lease_token')
```

Leases expire after 5 minutes. Renew with PATCH, release with DELETE.

### 2. Apply Operations

```bash
curl -s -X POST \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "lease_token": "'$LEASE_TOKEN'",
    "base_revision": 1,
    "change_summary": "Updated goals section",
    "operations": [
      {
        "op": "replace_exact",
        "old_text": "old text here",
        "new_text": "new text here",
        "count": 1
      }
    ]
  }' \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/operations" | jq .
```

**Important:** Set `base_revision` to the plan's `current_revision`. Returns 409 if stale.

### 3. Release Edit Lease

```bash
curl -s -X DELETE \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"lease_token": "'$LEASE_TOKEN'"}' \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/lease"
```

### Renew Lease (if needed for long edits)

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"lease_token": "'$LEASE_TOKEN'"}' \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/lease" | jq .
```

## Available Operations

### replace_exact

Find and replace exact text. Fails if text not found or count exceeded.

```json
{
  "op": "replace_exact",
  "old_text": "We should use MySQL",
  "new_text": "We should use PostgreSQL",
  "count": 1
}
```

### insert_under_heading

Insert content after a markdown heading. Fails if heading not found or ambiguous.

```json
{
  "op": "insert_under_heading",
  "heading": "## Testing Strategy",
  "content": "- Add integration tests\n- Mock external providers"
}
```

### delete_paragraph_containing

Delete the paragraph containing a needle string. Fails if 0 or >1 paragraphs match.

```json
{
  "op": "delete_paragraph_containing",
  "needle": "This approach is deprecated"
}
```

## Commenting

### Create Comment Thread

```bash
curl -s -X POST \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "body_markdown": "This section needs more detail.",
    "anchor_text": "the exact text you are commenting on",
    "agent_name": "Amp"
  }' \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/comments" | jq .
```

- `anchor_text`: the exact text from the plan content that this comment is about. It will be highlighted in the UI and the comment will be anchored to it.
- Omit `anchor_text` for a general (non-anchored) comment.
- `agent_name`: optional identifier for the agent (e.g., `"Amp"`, `"Claude"`). Displayed in the UI as "User Name (Agent Name)".

### Reply to Thread

```bash
curl -s -X POST \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"body_markdown": "Good point, I will address this.", "agent_name": "Amp"}' \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/comments/$THREAD_ID/reply" | jq .
```

### Resolve Thread

Mark a comment thread as resolved (addressed by the plan author or thread creator).

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/comments/$THREAD_ID/resolve" | jq .
```

### Dismiss Thread

Dismiss a comment thread (plan author only — for comments that are out of scope or not applicable).

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/comments/$THREAD_ID/dismiss" | jq .
```

## Reviewing a Plan

When asked to review a plan (given a plan URL or ID), follow this workflow:

### 1. Read the Plan and Comments

Fetch the plan content and all comment threads:

```bash
curl -s -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID" | jq .

curl -s -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/comments" | jq .
```

### 2. Triage Comments

Review each open comment thread and categorize it:

- **Just do it** — Clear, actionable feedback that can be applied directly (typos, clarifications, missing details where the fix is obvious). Apply these edits without asking.
- **Confirm first** — Substantive changes where the right fix is clear but the scope is large enough to warrant confirmation. Summarize the proposed change and ask the user before applying.
- **Discuss** — Ambiguous feedback, disagreements, or comments that require a design decision. Present these to the user for discussion — do not attempt to resolve them.

### 3. Present Summary

Before making any changes, present a summary to the user:

> **Plan Review: [Title]**
>
> **Will apply (N comments):** [list each with a one-line summary of the change]
>
> **Need confirmation (N comments):** [list each with the proposed change]
>
> **For discussion (N comments):** [list each with the question/issue]
>
> Shall I proceed with the "just do it" edits?

### 4. Apply Edits

For approved changes:

1. Acquire an edit lease
2. Apply operations (use `replace_exact`, `insert_under_heading`, or `delete_paragraph_containing`)
3. Release the lease
4. Resolve each comment thread that was addressed

### 5. Resolve Threads

After applying edits, resolve the comment threads that were addressed:

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $PLANNING_API_TOKEN" \
  "$PLANNING_BASE_URL/api/v1/plans/$PLAN_ID/comments/$THREAD_ID/resolve" | jq .
```

## Typical Workflow

1. **Read** the plan: `GET /api/v1/plans/:id`
2. **Acquire lease**: `POST /api/v1/plans/:id/lease`
3. **Apply operations**: `POST /api/v1/plans/:id/operations` (can call multiple times while lease is held)
4. **Release lease**: `DELETE /api/v1/plans/:id/lease`
5. **Comment** on changes: `POST /api/v1/plans/:id/comments`

## Error Codes

| Code | Meaning |
|------|---------|
| 401 | Invalid or expired API token |
| 403 | Not authorized for this action |
| 404 | Plan not found (or no access) |
| 409 | Edit lease conflict or stale revision |
| 422 | Validation error or operation failed |
