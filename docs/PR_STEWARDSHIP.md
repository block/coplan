# PR stewardship

Coplan's maintainer is Hampton, [@HamptonMakes on GitHub](https://github.com/HamptonMakes).
He makes the final product and acceptance decisions. Agents handle routine
engineering preparation so his review can focus on whether the feature belongs
in Coplan and feels right to use. Apply the same quality bar to every contributor.

This is the workflow for agents assigned to help maintain Coplan PRs. It is not
a requirement that every outside contributor run an agent or host a local server.
Follow [the contribution guide](../CONTRIBUTING.md), [agent guidelines](../AGENTS.md),
and [design guidance](DESIGN.md). Favor correctness, native-feeling interactions,
clear behavior, simplicity, and maintainability over clearing the queue quickly.

## 1. Notice and assign

- The coordinating agent watches all new PRs and assigns one worker chat per PR.
- Attach the actual GitHub PR to its chat, using the app's PR attachment feature
  when available. A number in the title is not an attachment. Include a clickable
  PR link in handoffs even when attachments are unavailable.
- Read the changes, description, existing feedback, and the author's readiness
  signals. Check CI and mergeability immediately.
- Watch draft and WIP work without forcing it through the full review cycle.
  Start the cycle when the author marks it ready or offers a reviewable prototype.

## 2. Request automated reviews

For review-ready work, check which automated reviews already cover the changes.
Post `🤖 @codex review` when a Codex review is needed. Also request GitHub Copilot
review when supported. Avoid duplicate requests for reviews already in progress.

Check back after roughly 30 minutes. If a review is still running, keep monitoring;
elapsed time does not count as approval. Record which commit each review covered.
Read findings and replies, verify claims, and combine duplicate findings. A bot
can be wrong, and green CI is not a substantive code review.

If a reviewer is unavailable, report the limitation. Do not present the review
as passed or silently waive a required gate; Hampton decides any exception.

## 3. Clean up before Hampton's review

Assigned maintenance agents may fix confidently understood technical findings,
resolve simple merge conflicts, commit, and push to the PR branch. They may request
reviews, reply to feedback, and resolve addressed GitHub review threads. These
routine steps do not need a separate permission request each time.

- Refresh the PR head and base before integrating changes. Preserve newer author
  commits and both sides' intended behavior. Do not overwrite another person's work.
- Resolve straightforward conflicts and test the combined behavior. If a conflict
  needs author context, explain the exact files and unresolved choice to the author.
- Investigate CI failures and fix relevant regressions. Report suspected flakes or
  unexplained failures to the coordinating agent with evidence. Do not hide failures
  by repeatedly rerunning CI or weakening tests.
- Run appropriate checks and **push the fixes**. A local-only patch is not ready.
- After every push, monitor CI to completion on the new head and recheck mergeability.
  Distinguish merge conflicts from missing approvals or other branch protections.
- Reply to addressed findings with a `🤖` explanation and commit or test evidence.
  Resolve threads only when the finding is addressed or demonstrably inapplicable.

Bring consequential product, design, behavior, or architectural choices to Hampton.
Do not silently make a foundational change to satisfy a bot. Handle routine
implementation choices independently, and keep contributor communication respectful.

## 4. Hand off a clean local tryout

Before marking work ready for Hampton, verify that:

- The author considers it ready, or it is an explicitly reviewable prototype.
- Automated reviews are complete and actionable technical findings are addressed.
- Changes are pushed, current-head CI is green, and merge conflicts are cleared.
- The local preview matches the reviewed code and the feature has been exercised.
- The PR is attached to its chat when supported and linked in the handoff.

For UI work, provide a running server, exact URL, login, short tryout path, expected
behavior, and light/dark evidence. Use isolated checkouts and dedicated databases;
preserve other workers' servers and data. Keep the preview available for feedback.
For API or command-line work, provide an equivalent runnable example and result.

Summarize what changed and any consequential product choice. Post the cleanup
summary described below on the PR before asking Hampton to spend time reviewing it.

## 5. Implement Hampton's feedback and repeat the checks

Read feedback directly in the worker chat as well as on GitHub. Carry requested
revisions through implementation, tests, and publication. Do not ask again for
authorization Hampton has already given for that scope.

After every push, check CI and mergeability again. Repeat Codex and, when supported,
Copilot review after major refactors, rebuilt behavior, or substantial changes from
Hampton's feedback. Small, bounded corrections do not automatically need a new
review round: explain the fix, resolve the finding when appropriate, and wait for CI.
Record why the existing review still covers the change when a new round is unnecessary.

Post another cleanup summary after this phase. A working local revision is not the
end of the loop: the PR must contain it, with the applicable reviews and checks complete.

## PR cleanup summaries

After **each full cleanup phase**, both before Hampton's review and after revisions,
post a concise PR comment prefixed with `🤖`. Include:

- What the agent changed, with relevant commits and addressed findings.
- What **Hampton (@HamptonMakes) requested**, especially when he gave the instruction
  in a local chat and it is not already recorded on the PR. Distinguish his request
  from the agent's recommendation; do not invent approval or quote private context.
- Tests, current-head CI, automated review results, and mergeability. State pending
  checks honestly and update the result when they finish.
- Screenshots or a short recording when the revised UI looks or behaves differently,
  with before/after evidence when useful. Use shareable PR attachments, not local paths.
- Any remaining decision, limitation, or agreed follow-up.

Individual review replies complement this summary; they do not replace it. Keep
summaries useful to the original author and readers who cannot see the local chat.

## 6. Final acceptance and merge

Hampton authorizes approval and merging for the PR. Routine maintenance permission
is not permission to approve or merge. Once authorized, finish the checks without
asking for the same permission again:

- Requested changes are implemented and pushed; no actionable findings remain.
- The required automated review rounds cover the final scope.
- CI is green on the current head and there are no merge conflicts.
- The scope still matches what Hampton authorized.

Then approve and/or merge within that authorization. Recheck the head immediately
before merging; new commits need assessment. Never bypass branch protections to
make the queue look clean.

## 7. After merge

Verify that GitHub records the merge and report the resulting commit. Check any
applicable post-merge checks and distinguish merged code from released or deployed
code. Record agreed follow-ups with links so they are not lost when the chat closes.
Mark work done and archive its chat only when no requested tryout, feedback, or
follow-up work remains in that chat. Keep a preview alive while it is still needed.

For major releases, assign a separate chat to prepare release notes and announcement
copy for the **#coplan** Slack room. Use the actual release range, verified features
and fixes, compatibility notes, demos, and contributor credit. Verify the channel
before sending. Preparing copy is routine; publishing a release or sending the
announcement requires authorization for that action.

## Queue labels and coordination

Use specific feature names and PR numbers with these labels:

| Label | Meaning |
| --- | --- |
| WATCHING | Draft or WIP; not yet in the full review cycle |
| PREPARING / FIXING | Engineering or automated review work remains |
| FIXING CONFLICTS | Known merge conflicts are being resolved |
| WAITING ON AUTHOR | A concrete question needs author context |
| NEEDS DECISION | Hampton must make a consequential choice |
| TRY THIS / READY FOR REVIEW | The engineering gates passed; Hampton can review |
| APPROVED | Hampton accepted the scope; final checks or authorized merge remain |
| DONE | Authorized work and applicable verification are complete |

The coordinating agent keeps ownership, labels, PR attachments, reviews, CI,
mergeability, and previews accurate. Follow up when workers stall. Recheck gates
after base-branch changes; yesterday's green checks do not prove today's merge works.
Keep Hampton's attention on hands-on review and consequential decisions rather than
routine status reports.
