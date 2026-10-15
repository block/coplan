## Executive summary

Shared workspaces bring document ownership, review, and discovery into one place. Launch web first, then mobile after invitation and offline reading work end to end.

## Customer problem

Teams lose context when plans live in scattered chats and folders. A workspace should keep the decision, its reviewers, and the resulting edits together.

## Audience

Start with engineering teams who review at least one design per week. Product and operations teams join the pilot after the first review loop is reliable.

## Principles

Make the next useful action visible. Preserve reading position. Show who changed a decision and why.

## Goals

Reduce the time to first useful reply and make agreed decisions easy to find later. Measure both outcomes for each pilot team.

## Non-goals

The first release does not replace project tracking, chat, or source control. It links those systems to the plan.

## Jobs to be done

An author needs a reviewer; a reviewer needs context; a returning teammate needs the current decision and its history.

## Information architecture

Each person has a library. Folders organize documents, while published plans remain discoverable across the workspace.

## Web navigation

Keep the sidebar width stable across library, document, and settings views. Prefetch real navigation on hover.

## iOS navigation

Open documents in a reading view with a compact table of contents. Keep reply controls reachable above the keyboard.

## Android navigation

Use the same information hierarchy as web. Back returns to the previous library position.

## Small-screen table of contents

Long heading lists scroll independently. Selecting a heading closes the outline and preserves a clear reading location.

## Workspace creation

Ask for a name and create a usable empty workspace. Invite a reviewer after the first document exists.

## Invitations

Persist invitations before sending them. Delivery retries reuse the same invitation ID.

## Roles and permissions

Authors edit their plans. Reviewers discuss decisions. Approvers record an explicit approval.

## Document placement

A document has one library placement. Moving it preserves readable URLs through aliases.

## Folder behavior

Folder names provide location; descriptions explain what belongs there. Avoid duplicating the folder name in every title.

## Search

Search headings and body text. Exclude archived documents by default and keep private drafts out of discovery.

## Activity

Show attributed versions and discussions in time order. Group related filing changes under one organize run.

## Notifications

Unread messages need attention. Opening the discussion acknowledges reading without resolving it.

## Empty states

An empty library explains how to add a plan. An empty review queue confirms that nothing needs a response.

## Loading and offline states

Show progress immediately and keep existing content visible. Failed requests provide a retry action in place.

## Accessibility

Every action works by keyboard. Focus rings use blue and do not depend on color alone to convey state.

## Localization

Test long translated headings and right-to-left prose. Dates and names must remain legible in narrow layouts.

## Analytics

Measure first document, first invitation, first reply, and return visits. Keep private document text out of analytics.

## Privacy

Publish only after an explicit visibility decision. Direct draft links are shareable, so the interface must explain the boundary.

## Performance budgets

Document navigation should preserve layout and show cached content immediately. Measure the slowest pilot devices.

## Migration

Import a small set of existing plans first. Compare content, references, and ownership before expanding.

## Rollout

Start with internal teams, then a small customer cohort. Pause on permission errors or lost comments.

## Support readiness

Provide receipt IDs and a reproducible recovery path. Support can diagnose delivery without reading private content.

## Risks

The largest risks are unclear ownership, noisy attention indicators, and lost context after a move. Exercise each before launch.

## Open questions

Should teams have shared libraries? What signals should make an approver return after an edit?

## Decision log

The pilot uses personal libraries and explicit approvers. Revisit team libraries after measuring cross-team discovery.

## Appendix: terminology

A plan is a versioned Markdown document. A thread is a discussion. A library is a folder tree owned by a person.
