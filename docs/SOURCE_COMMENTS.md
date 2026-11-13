# Comments on diagram elements and table cells

Double-click an inline table or diagram to expand it; drag expanded diagrams to pan.
Table expansion keeps the double-clicked cell selected and visible.
Diagrams start in browsing mode. Press C or choose Comment in the expanded
toolbar to enter comment mode, clearing any text selection, then hover a
supported flowchart node or connection to reveal a blue glow and comment cursor. Select
one to open its discussion with the comment or reply box focused. Escape closes
the discussion first, then exits comment mode. Other diagram families offer
an explicit whole-diagram comment action, anchored to the complete fenced block.
This fallback never claims to identify an individual item. Clicking a table cell selects
it for reading; press C or Enter to comment. Expanded tables also provide a
Comment button with a C keycap in the footer, without a floating action over cells.
Clicking an existing discussion badge opens it directly. Selecting text shows
only a Comment action; press C or choose that action to open the composer.
Keyboard users can also focus a target and press Space. Escape dismisses the panel and returns
focus to the target. Comments use the standard text-comment composer and thread styling, positioned
beside the target on desktop and as a bottom sheet on narrow screens. Closing or switching targets preserves
unsent drafts for the current page visit.

The expanded table and diagram use the same discussions as the document.
Table sorting does not change a comment's source identity; header cells have
separate sort buttons. Diagram dragging/pinching remains navigation, and
connections have a transparent 24px hit area. Markdown links remain links.
Existing text-selection comments continue to work.

Dense prose tables open with wrapped cells. There is no duplicate value pane
or layout shift when selecting a cell. In compact mode, R or Expand row shows
the selected row's full text in place; R or Collapse row folds it again.
Wide tables retain horizontal scrolling,
a pinned first column and header, and keyboard navigation to every cell.

`spec/fixtures/rich_views` exercises paragraph-heavy tables, long identifiers,
and eight Mermaid examples spanning flowcharts, sequences, states, classes,
entity relationships, mindmaps, and Gantt charts. The browser stress spec also
checks a 120-row, 24-column table and commenting on its far corner. Diagram
rendering coverage is distinct from the source-comment syntax described below.

Hover, keyboard focus, active selections, and new-comment context use blue
interaction styling in both modes. Open discussions keep small muted badges.
Unresolved does not mean unread: orange is reserved for a viewer's outstanding
task or review attention, as defined in [the design guidance](DESIGN.md).

## Source identity and edits

The renderer emits a signed, content-bound source token for each target.
The server validates that token against the current content while holding
the plan lock. It stores the existing `anchor_start`, `anchor_end`,
`anchor_revision`, `anchor_text`, and `anchor_context`, plus `anchor_kind`
(`table_cell`, `mermaid_node`, `mermaid_edge`, or `mermaid_diagram`). These fields are returned
by the existing plan/comment API. Offsets are **zero-based Ruby character
indices**, with an exclusive end; they are neither bytes nor JavaScript
UTF-16 indices. The agent API returns the exact underlying Markdown source.

Cell ranges include their original Markdown formatting, escaping, and
whitespace. Empty cells between pipes include both pipes, so inserting a
value inside the cell conflicts with the old anchor. Node ranges identify
the explicit declaration, or the first reference if there is no declaration.
Connection ranges include both endpoints and the link syntax, even when the
connection has no label. Parallel connections have separate source ranges.

Existing operational transformation moves ranges through unrelated edits.
Overlapping edits, removed targets, and changes that stop the source from
representing a supported element mark a thread out of date. The document's
**Outdated element comments** button retains access to these discussions.
Their source context uses the last successfully tracked revision. A stale
browser selection is rejected; the form retains its draft and asks the
reader to reopen the latest plan before posting.

## Markdown blocks

A `markdown` or `md` fence renders in the reading view as a Markdown block:
the rendered draft, a Rendered / Source switch, and the literal source,
hidden while Rendered shows. Each page load opens blocks in the reader's
default view, set under Settings → Appearance (Rendered unless changed). A
live update keeps the view chosen on that page, including when the draft is
edited. The existing live-update swap maps the block through the shared text
diff before restoring the viewport.

Text selections in Markdown blocks create ordinary comments with no `anchor_kind`.
Table-cell and nested Mermaid comments use the existing signed structural targets, translated
from the draft body into document source offsets. They work inline and in the
expanded table or diagram; Source shows the same discussion on its literal text.
The hidden source stays in the browser's anchor text model in both views, and
the rendered pane stays out of it. This keeps occurrence counting the same as
for any code block, on the client and in `MarkdownTextExtractor`.

- The server marks each rendered element with the body range it came from
  (`data-markdown-from` and `data-markdown-to`, UTF-16 offsets into the
  fence body). The block also carries the parser-backed visible text and
  complete source spans from `MarkdownTextExtractor`. `coplan/markdown_blocks.js`
  matches each text node within its element's range and advances parent
  cursors after nested formatting. Link URLs cannot match visible labels.
  Entities and escapes map to their whole source spelling. Footnote
  numbers and other generated text do not map. Raw HTML blocks receive their own trusted AST source intervals, so identical
  footnote text relocated later in the DOM cannot become a candidate.
  Authored IDs and source-position attributes are stripped before rendering;
  they cannot claim generated coordinates or footnote targets.
- A selection in the rendered draft becomes the source range from its first
  to its last mapped character. A selection across `**bold**` text or a link
  therefore stores the Markdown source of that passage.
- When Rendered shows, a highlight that falls in the hidden source is drawn
  over the rendered characters that came from that range. A comment made in
  either view shows in both.
- A comment anchored only to text with no rendered form, such as part of a
  URL, is visible in Source only.
- Only a fence the parser produced becomes a block. Authored HTML imitating
  one stays ordinary HTML. Fences inside slide decks, editor previews, and
  comments stay code blocks. Structural discussions become outdated if an edit
  moves their draft into a literal slide fence.
- Writing inspection keeps attribution on canonical source. The Rendered/Source
  buttons remain available during inspection so that source attribution is reachable.

## Supported syntax

- Markdown table header and body cells, including repeated values, Unicode,
  formatting, escaped pipes, and explicit empty cells bounded by pipes.
  Synthetic cells inserted by the Markdown renderer for missing columns
  have no source to select and remain unselectable.
- Mermaid `flowchart` and `graph`, ordinary single-line node declarations,
  chains, single-line `@{ ... }` shape declarations, standard arrows, pipe/text connection labels, semicolons, subgraphs,
  and styling directives. Mapping is additionally checked against the pinned
  Mermaid parser's complete edge sequence and generated element IDs.
- A node with multiple explicit declarations is unselectable because it
  does not have a unique declaration. Other unambiguous targets still work.
- Other Mermaid diagram types, grouped endpoints (`A & B --> C`), explicit
  edge IDs, multiline attributes/labels, and unrecognized syntax
  do not receive element targets. The entire diagram remains viewable,
  expandable, and commentable as a whole; the mapper never guesses an edge's source. Nested fences whose
  rendered body differs from the literal source also have no element targets.
- Element comments are available in document views, not slide decks.

Run migrations in the host after installing the engine migration. No new
comment lifecycle or editing API is required: resolve, reopen, notifications,
and agent replies use the existing endpoints.
