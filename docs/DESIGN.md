# Interaction and attention

Reading is the primary activity. Apply these rules consistently to document
text, tables, diagrams, rich previews, expanded views, and editors, in light
and dark themes.

Selecting a table cell is a browsing action. Keep its composer closed until
the reader presses C or Enter, chooses Comment, or opens a discussion badge.
Text selection similarly offers a Comment action without opening a composer.
Double-click an inline table or diagram to expand it. Tables preserve the clicked
cell (including headers) and reveal it around the pinned header and first column.
Diagrams browse by default. Show the Comment mode button only in expanded
diagrams; the inline overview stays free of an idle comment toolbar.
C or Comment clears any text selection and enters comment mode without focusing
or selecting an item; Tab
explicitly moves to a target. Escape returns to browsing. Preserve the
diagram’s authored appearance until a commentable target is hovered or keyboard
focused, then show a restrained blue glow and a speech-bubble pointer. Browsing must not
highlight connection lines or switch cursors between shapes and labels. Expanded
diagrams use a grab cursor for panning. Clicking a glowing
target focuses the comment or reply field immediately. Other diagram types
offer a clearly labeled whole-diagram comment action. Preserve copying and
arrow navigation. Selecting a table cell must not insert a value pane or move
the grid. In compact tables, R or Expand row reveals a row's complete text in
place; collapse is also explicit. Wrapped tables already show the full text. Cell comment composers and discussions
use the selected cell as context without repeating its contents in a quote.
Resolving a discussion closes its panel; it must not linger after its badge disappears.
Connection labels are part of the comment target, and badges sit beside labels
in front of the diagram artwork.

Fit means the entire diagram is visible, both in the document overview and
the expanded view. Never impose a readability zoom floor on Fit; zoom and
Actual size provide detail. Comment hover glows must cover nested SVG shapes
and connections without adding dotted outlines or altering authored line styles.

| State | Treatment |
| --- | --- |
| Hover | Subtle blue tint for tables; diagrams glow only in comment mode |
| Keyboard focus or selection | Clearly visible blue focus/selection indicator |
| Writing a comment or reply | Blue selection and quoted context |
| Viewing a discussion | Blue selected context; no unread orange once opened |
| Unresolved, already read discussion | Compact blue badge with a clearly legible count |
| Unread material for this viewer | Orange attention indicator until reviewed |
| Task requiring this viewer's action | Orange until completed or explicitly acknowledged |
| Resolved discussion | Hidden by default; available through Show resolved |

## Orange requires a reason

Orange is a request for the current viewer's attention. An awaiting-input
agent, an editing conflict, or an unread review item can justify it. Hover,
focus, selection, typing, opening a panel, and the existence of an unresolved
conversation cannot. User-authored content may of course contain its own colors.

Keep read state separate from thread lifecycle. Opening an unread discussion
by click, keyboard, permalink, or a readable preview acknowledges its review
attention immediately. Update all inline and expanded representations together,
persist that acknowledgement for this viewer, and reconcile if persistence
fails. A subsequent new reply may restore unread attention. Reading alone must
never invoke Resolve or mark another person's notifications read.

An actionable task, such as resolving an editing conflict, remains actionable
after its details are opened; clear its orange when the task is completed or
acknowledged. Always provide a label or other non-color cue for attention.

## Shared implementation

Use `--color-interaction-hover-bg` and `--color-interaction-active-bg` for
table backgrounds, `--color-primary` for focus and selection, and
`--color-quote-info-*` for quoted comment context. Reserve `--color-warning*`
and orange pending tokens for actual attention states. Shared components must
keep these meanings when cloned or moved into an expanded view.

Currently, opening a plan clears that viewer's plan notifications. Rich comment
badges describe unresolved discussions; they do not represent per-thread unread
receipts. Do not color them orange based on `open` status. Any future per-thread
unread indicator must implement the acknowledgement lifecycle above using
viewer-specific state rather than a local color toggle.
