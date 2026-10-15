## Readable inline formatting

Use **bold** for a decision, *italics* for emphasis, ~~strikethrough~~ for an abandoned option, and `receipt_id` for code. Ask [@alex](mention:alex) about the rollout boundary.

### A smaller heading

> Keep the receipt stable across retries.
>
> A delivery attempt can fail without invalidating the invitation.

## Tasks and nested lists

- [x] Define a receipt
- [ ] Inspect retry metrics
- [ ] Publish the beta summary

1. Create an invitation.
2. Deliver it.
   - Retry transient failures.
   - Stop after expiration.
3. Confirm membership.

## Two code languages

```ruby
receipt = InvitationReceipt.find_by!(id: receipt_id)
receipt.deliver_unless_expired!
```

```json
{
  "receipt_id": "beta-001",
  "status": "queued"
}
```

## Image and supporting detail

![CoPlan logo]({{demo_logo_url}})

The logo opens in an expanded image view. A footnote keeps the supporting detail nearby.[^demo]

[^demo]: This example intentionally combines the common Markdown surfaces in one short document.
