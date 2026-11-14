A `markdown` or `md` code fence holds a draft written somewhere else: a
status update, a release note, a message to post. The reading view shows it
rendered, the way it will look where it goes. Switch the block to **Source**
to read the literal Markdown. Every page load starts on Rendered.

Comment on either view. A comment is stored against the source text, so it
shows in both views. Select text in the rendered draft, press C, and then
switch to Source to see the same passage highlighted.

## Project update draft

Post this to the project once the last ticket closes.

```markdown
**Progress**

* The November rollout is done. Every ticket in this project is closed.
  * Retries end with a clear "Too many attempts" screen.
  * The lockout check runs in production ([release notes](https://example.com/releases/42)).
* The integration guide is published for partner teams.

**Plans**

* Launch close-out: remove the old flag and archive the dashboard.
* Hardening: correctness and rate-limit fixes.

**Problems**

* None.
```

## Release note with a table and a footnote

Double-click a cell to expand the table. Press C or choose Comment to discuss
the selected cell, then switch the block to Source to see its source highlight.

```md
### Retry budget

| Client | Attempts | Backoff |
|---|---|---|
| Mobile | 3 | 2 s |
| Web | 5 | 1 s |

The web budget is higher because sessions last longer.[^budget]

[^budget]: Measured over the last 30 days of traffic.
```

## An ordinary code block

Other languages stay code. This one is shown as written:

```text
**This stays literal text.**
```
