# Human document editor prototype

Owners use **Edit** to write in the document. **Editer**, **Raw**, and **Dual** are
first-class modes sharing one draft, base revision and autosave pipeline. The
workspace **New document** starts a private draft. Add a title and content and it saves in
place, without replacing the editor or interrupting typing.

Run `bundle exec rails server -p 3100` from the host app and sign in at
`http://localhost:3100/sign_in`. ProseMirror loads through pinned importmaps;
first load requires esm.sh. There is no Node/build step.

## Everyday editing

Rich mode shares reading-view typography. The compact toolbar provides selected
states, accessible labels and shortcut hints. The link button uses the same
Lucide outline convention as the app; style controls and native options follow
light/dark themes. Cmd/Ctrl+B/I format, Cmd/Ctrl+Z undoes, Cmd/Ctrl+Shift+Z redoes,
and Cmd/Ctrl+K adds a link. Lists support Enter, Tab and Shift+Tab.

Changes autosave after a 900ms pause. Cmd/Ctrl+S flushes immediately. **Back** is
the single navigation action: it waits for an in-flight save, saves any newer
valid draft, then returns to reading view. Back disables hover prefetch because
its destination must reflect the completed save; navigation clears stale Turbo
snapshots. Failed saves, invalid titles and
unresolved conflicts keep you in the editor with your draft. An untouched empty
new draft can simply go Back. Comments remain available in reading view.

## Markdown, tables and diagrams

Raw mode edits the exact Markdown source in a plain, unformatted editor. Switching
modes alone does not serialize, save or normalize the text, including unsupported
syntax. Each mode keeps its selection and undo history for the current visit;
incoming edits map through both editors without focusing the background pane. Source-card **Edit Markdown** buttons switch modes and
select the block's source. The source mode has ordinary text Enter/Tab and
Cmd/Ctrl+Z/Shift+Z; rich toolbar controls are hidden there.

Tables render as table previews with **Edit Markdown** above them. Edit table
cells/rows/alignment in source, then switch back to see the result. There are no
visual table insertion or cell-editing controls in this prototype.

Mermaid fences show editable Mermaid source plus a rendered diagram preview.
The preview refreshes after edits, uses the app's Mermaid renderer and follows
the theme. Its expand button opens the existing diagram viewer. **Edit Markdown**
selects the whole fence for exact source editing. Invalid/offline previews keep
the source available; they do not discard or replace it.

Other unsupported Markdown (task lists, footnotes, raw HTML, reference-style
links, strikethrough and mentions) remains source-preserving. Cards show a
sanitized reading-style preview when available, with the same source-edit path.
Untouched blocks retain their exact spelling. A supported block that you edit
in rich mode is reserialized; Markdown mode gives full control over spelling.
Slides remain deferred.

## Code blocks

Use the toolbar **Insert code block** button to open a dropdown directly beneath
it. Search languages and click a suggestion, or use arrow keys and Enter to
insert the selected language. Type custom fence info and press Insert when no
suggestion fits. Escape dismisses the dropdown. The style selector also converts
the current text block; inline code remains a separate formatting action.

Every fenced block has a window-style header with an editable language name
and suggestions (Ruby, JavaScript, Python, SQL, JSON, Mermaid, and others).
The red close button deletes that code block; Undo restores it, including its
language and contents. Custom fence info is supported except backticks/newlines.
Changing the field changes the Markdown fence info and keeps the code content.
Language changes participate in undo/redo, autosave and incoming-version merges.
Selecting `mermaid` enables the diagram preview; switching to another language
keeps its source as ordinary code. This does not provide a visual diagram editor.

Enter adds a code line and carries forward its leading whitespace. Tab inserts
two spaces. Ordinary code blocks have no redundant Edit Markdown button. ArrowDown at the end of the block moves into the next existing text block,
skipping preserved Markdown separators without inserting a blank paragraph; a final code block already has an editable empty paragraph after it. You
can also click that empty paragraph directly. There is no visible “Write below”
label. That empty editing affordance contributes no
Markdown until you type, so opening, navigating or switching modes cannot add
blank paragraphs to otherwise untouched source.

Editable code uses the existing pinned highlight.js 11.11.1 core and lazy
language grammars. Its escaped output is parsed in a detached tree and converted
to ProseMirror decorations; highlight.js never rewrites the editable contentDOM.
Aliases such as `js`, `rb` and `py` resolve to canonical grammars. Only the first
fence-info token selects a grammar; metadata is retained. Language changes
refresh tokens, and theme variables match the reading view. Blank, plain-text,
Mermaid and unknown/offline grammars remain editable without syntax tokens.
Mermaid retains its separate rendered preview.

Highlighting waits 100ms after document changes, defers during composition,
ignores stale async results, and caches up to 40 block results. Blocks over
20,000 UTF-16 code units and eligible content beyond a 100,000-unit per-document
budget remain plain. These bounds limit synchronous tokenization work; this is
not a virtualized large-file code editor. Decoration-only transactions neither
change Markdown nor enter undo/autosave history.

## Dual mode and engine configuration

Dual places editable Markdown on the left and rich text on the right; below
800px they stack. Both panes share a single canonical draft and save queue.
ProseMirror transactions notify the controller once; counterpart updates are
marked remote and do not echo back or create undo events. Each pane retains its
own history. Keyboard undo and toolbar Undo/Redo operate on the last focused
pane; formatting controls act on rich text. Structural source rewrites can
invalidate older undo steps or move a mapped selection; this is not shared CRDT
history. IME composition defers counterpart updates and incoming responses
until ProseMirror has reconciled the composition DOM.

Select All is scoped to the focused surface: Cmd+A on macOS, Ctrl+A elsewhere.
Within a rich code block it selects only that block's code text; in rich prose
it selects the rich document body, and in Markdown it selects the raw source.
Title and language inputs retain native value selection. Dual respects the
focused pane. Outside editor controls the app does not intercept Select All.
macOS Control+A moves to the current code/source line's start. The shortcut uses
the current native caret because a click can precede ProseMirror's asynchronous
selection reconciliation.

Hosts configure suggestions in their Rails initializer, then restart the app:

```ruby
CoPlan.configure do |config|
  config.editor_code_languages = %w[text ruby javascript sql mermaid elixir]
end
```

The engine defaults are `text ruby javascript typescript python sql json yaml
bash html css go java rust mermaid`. These are suggestions, not an allowlist.
Existing custom languages and extra fence info remain supported and preserved.

The editing core is **ProseMirror**, not an editor built from scratch. CoPlan's
lossless Markdown bookkeeping, source/code NodeViews, pane synchronization,
autosave, recovery, and server merge integration are custom code.

## Cooperative saving and recovery

Opening a document acquires no human session lease. A plan row lock is held only
while committing. Three-way comparison of the immutable base, draft and current
server version merges disjoint character ranges (including one paragraph) and
deduplicates identical edits. Different edits to overlapping ranges pause for
review. Title/tags use their own three-way comparisons. Active agent leases and
the established HumanEditGuard/read-receipt fence remain enforced.

For an opened document, real ActionCable/Turbo broadcasts trigger a fresh
snapshot after an 80ms debounce. The editor also observes the existing
`plan-history-list` event from `PlanVersion.after_create_commit`, since content
and header events can precede transaction commit. A queued broadcast during a
save, fetch or composition is reconciled afterward. Delivery reflects committed
revisions, with websocket, debounce and snapshot-request latency; it does not
stream an agent's unsaved keystrokes. A 2.5-second visible-tab poll handles missed
broadcasts and reconnects. In-place creation returns the same server-rendered,
signed Turbo subscription as opening an existing editor and installs it as soon
as creation succeeds. Turbo manages connection and removal of that element;
mode changes retain one subscription. A connection/reconnection triggers a
snapshot refresh to catch revisions committed before subscription confirmation
or during a disconnect. Navigation disconnects the observer and removes the
subscription with the editor DOM. Mapped ProseMirror transactions preserve selection and
local undo for incoming text/formatting changes. Typing during a save is merged
against the submitted snapshot and saved next. IME composition defers syncing.
Every content commit remains an immutable version with its normal actor identity.
The prototype's contribution percentages/UI/endpoints have been removed.

Unsaved source, title, tags and original base snapshot live in browser-local
storage separated by user, document and editor instance. Reload can recover the
draft without granting permission to overwrite newer edits. Failed requests,
expired sign-in and uncertain responses never count as acknowledged saves.

A conflict retains the draft and shows the latest saved source. Download the
draft, use the saved version, or explicitly confirm replacement of the reviewed
revision. Further intervening changes conflict again. Back never bypasses this.
Browser drafts are not cross-device backups; local undo does not survive reload.
This is cooperative Markdown editing, not a full CRDT: overlaps need review and
large structural rewrites can move the selection to the changed range.

## Verification

Run `bundle exec rspec`. Concurrent worktrees need distinct test databases via
`DATABASE_URL`, so one suite cannot reset another suite’s schema or data.
`spec/system/document_editor_modes_spec.rb` covers mode
fidelity, table/Mermaid previews, Back success/error/conflict/in-flight behavior,
raw live merging and undo, code exit/language, themes and new-document autosave.
`spec/system/human_editing_spec.rb` covers the existing keyboard, draft, merge,
persistence and reading flows. Request/service tests cover sanitized previews,
authorization, atomic saves, surgical ranges, immutable versions and conflicts.

`spec/system/editor_code_controls_spec.rb` covers anchored desktop/narrow dropdown
placement, mouse and keyboard autocomplete, dismissal without draft changes,
custom languages, JavaScript highlighting and saved fence info, and scoped
window deletion with undo/redo and Dual synchronization.

The code selection and highlighting specs use real browser keyboard input and
native selection, with replacement, undo, themes, language aliases and large-block
fallbacks. The caret spec checks vertical movement after Enter with syntax
highlighting enabled. The live-delivery specs disable polling, commit through
the real backend service and observe ActionCable/Turbo updates. They cover
clean/dirty/conflicting drafts, queued snapshots, in-flight saves, immediate
subscriptions after in-place creation, reconnect catch-up and cleanup on Back.

Composition regressions simulate browser composition events. A physical
non-Latin input-method session is not covered by this automation. Tests run
with the host platform's selection modifier; macOS also checks Control+A line
navigation.

A reported case where Enter appeared inert inside a code block has not been
reproduced in Chrome, the in-app browser, or a disposable copy of the saved
content. Passing caret tests do not establish that report's cause or resolution.
The original open draft was unavailable for inspection and was left untouched.
