import { diffArrays } from "diff"
import { codeHighlight } from "coplan/code_highlight"
import { textHunks } from "coplan/merge_text"
import { citationLabelKey } from "coplan/citation_labels"
export { citationLabelKey } from "coplan/citation_labels"
import { Schema, Fragment, Slice } from "prosemirror-model"
import { EditorState, TextSelection, Plugin, PluginKey } from "prosemirror-state"
import { EditorView, Decoration, DecorationSet } from "prosemirror-view"
import { MarkdownParser, MarkdownSerializer, defaultMarkdownParser, defaultMarkdownSerializer as baseMarkdownSerializer } from "prosemirror-markdown"
import { baseKeymap, toggleMark, setBlockType, wrapIn, lift, chainCommands, exitCode, selectAll } from "prosemirror-commands"
import { wrapInList, splitListItem, liftListItem, sinkListItem } from "prosemirror-schema-list"
import { keymap } from "prosemirror-keymap"
import { history, undo, redo, closeHistory } from "prosemirror-history"

const mac = /Mac|iP(hone|ad|od)/.test(navigator.platform)
const lineNavigation = mac ? { "Ctrl-a": codeLineStart } : {}
const commentKey = new PluginKey("coplan-comments")

// Preserve the exact source of untouched top-level blocks. Constructs outside
// the rich schema are atomic source cards, never silently parsed away.
let nodes = defaultMarkdownParser.schema.spec.nodes
nodes.forEach((name, spec) => {
  if (name !== "text") nodes = nodes.update(name, { ...spec, attrs: { ...spec.attrs, source: { default: null }, snapshot: { default: null } } })
})
nodes = nodes.addBefore("paragraph", "preserved", {
  group: "block", atom: true, attrs: { source: {}, kind: { default: null }, label: { default: null } },
  toDOM: node => ["div", { class: "document-editor__preserved", hidden: node.attrs.source.trim() ? null : "hidden", contenteditable: "false" },
    ["small", "Preserved Markdown block"], ["pre", node.attrs.source]]
})
nodes = nodes.addBefore("text", "footnote_reference", {
  inline: true, group: "inline", atom: true, attrs: { label: {} },
  leafText: node => `[^${node.attrs.label}]`,
  parseDOM: [{ tag: "sup[data-coplan-footnote]", getAttrs: dom => ({ label: dom.dataset.coplanFootnote }) }],
  toDOM: node => ["sup", { "data-coplan-footnote": node.attrs.label, class: "document-editor__footnote", title: `Reference: ${node.attrs.label}`, contenteditable: "false" }, ["button", { type: "button", "data-citation-label": node.attrs.label, "data-action": "coplan--editor#openCitation", "aria-label": `Edit citation ${node.attrs.label}` }, `[${node.attrs.label}]`]]
})
const schema = new Schema({ nodes, marks: defaultMarkdownParser.schema.spec.marks })
// Run before links, but after escapes and code spans. A citation is inline
// content, so it must not turn its entire paragraph or list into a source card.
const tokenizer = defaultMarkdownParser.tokenizer
tokenizer.inline.ruler.before("link", "coplan_footnote", (state, silent) => {
  const match = /^\[\^([^\]]+)\]/.exec(state.src.slice(state.pos))
  if (!match || !citationLabelKey(match[1])) return false
  if (!silent) state.push("footnote_reference", "", 0).meta = { label: match[1] }
  state.pos += match[0].length
  return true
})
// Keep a table's own node inside its surrounding list or blockquote. The
// list remains rich text; only the table uses a source-preserving preview.
tokenizer.enable("table")
tokenizer.core.ruler.after("block", "coplan_tables", state => {
  const lines = state.src.split("\n")
  for (let index = 0; index < state.tokens.length; index++) {
    const token = state.tokens[index]
    if (token.type !== "table_open") continue
    const end = state.tokens.findIndex((next, at) => at > index && next.type === "table_close")
    if (end < 0) continue
    const quoteDepth = state.tokens.slice(0, index).reduce((depth, current) => depth +
      (current.type === "blockquote_open" ? 1 : current.type === "blockquote_close" ? -1 : 0), 0)
    const source = lines.slice(...token.map).map(line => {
      for (let depth = 0; depth < quoteDepth; depth++) line = line.replace(/^ {0,3}> ?/, "")
      return line
    }).join("\n")
    const indentation = source.match(/^[ \t]*/)[0]
    const normalized = source.split("\n").map(line => line.startsWith(indentation) ? line.slice(indentation.length) : line).join("\n") + "\n"
    token.type = "preserved_block"; token.nesting = 0
    token.meta = { source: normalized, kind: "table" }
    state.tokens.splice(index + 1, end - index)
  }
})
const richMarkdownParser = new MarkdownParser(schema, tokenizer, {
  ...defaultMarkdownParser.tokens,
  footnote_reference: { node: "footnote_reference", getAttrs: token => token.meta },
  preserved_block: { node: "preserved", getAttrs: token => token.meta }
})
const defaultMarkdownSerializer = new MarkdownSerializer({
  ...baseMarkdownSerializer.nodes,
  footnote_reference: (state, node) => state.text(`[^${node.attrs.label}]`, false),
  preserved: (state, node) => {
    for (const line of node.attrs.source.trimEnd().split("\n")) { state.write(line); state.ensureNewLine() }
    state.closeBlock(node)
  }
}, baseMarkdownSerializer.marks)

const presentationOpen = /^::: \{\.presentation(?: #([a-zA-Z][\w-]*))?(?: theme="(coplan|graphite)")?\}$/
function contentRanges(tokens, lines, offsets, markdown, definitionsOnly = false) {
  const ranges = tokens.filter(t => t.level === 0 && t.map && t.nesting !== -1)
  const specials = []
  let opener = null
  for (const token of ranges) {
    const [from, to] = token.map
    if (token.type !== "paragraph_open" || to !== from + 1) continue
    const line = lines[from].replace(/\r$/, "")
    if (opener !== null) {
      if (line !== ":::") continue
      specials.push({ from: offsets[opener], to: Math.min(offsets[to], markdown.length), kind: "presentation" })
      opener = null
    } else if (presentationOpen.test(line)) opener = from
    if (line.startsWith("::: {.iframe ") && line.endsWith(" /}"))
      specials.push({ from: offsets[from], to: Math.min(offsets[to], markdown.length), kind: "iframe" })
  }
  // Definitions are metadata, not visible body blocks. Keep their exact source,
  // including indented continuation paragraphs, for citation editing and Raw.
  const excluded = ranges.filter(t => ["fence", "code_block", "html_block", "blockquote_open", "bullet_list_open", "ordered_list_open"].includes(t.type))
  for (let line = 0; line < lines.length; line++) {
    if (excluded.some(t => line >= t.map[0] && line < t.map[1])) continue
    const match = /^ {0,3}\[\^([^\]]+)\]:[ \t]*(.*)$/.exec(lines[line])
    if (!match || !citationLabelKey(match[1]) || (!definitionsOnly && specials.some(r => offsets[line] >= r.from && offsets[line] < r.to))) continue
    let end = line + 1
    while (end < lines.length) {
      if (/^(?: {4}|\t)\S?/.test(lines[end]) && lines[end].trim()) { end++; continue }
      if (!lines[end].trim() && /^(?: {4}|\t)[ \t]*\S/.test(lines[end + 1] || "")) { end += 2; continue }
      break
    }
    specials.push({ from: offsets[line], to: Math.min(offsets[end], markdown.length), kind: "reference", label: match[1] })
    line = end - 1
  }
  return specials.filter(range => !definitionsOnly || range.kind === "reference").sort((a, b) => a.from - b.from)
}
export function presentationContent(source) {
  let first = source.indexOf("\n") + 1
  // Blank separator lines belong to the wrapper, so replacing all of the
  // field cannot merge the closing marker into the last slide paragraph.
  if (source[first] === "\n") first++
  else if (source.slice(first, first + 2) === "\r\n") first += 2
  let last = source.lastIndexOf(":::")
  if (source.slice(last - 2, last) === "\n\n") last--
  else if (source.slice(last - 4, last) === "\r\n\r\n") last -= 2
  return { before: source.slice(0, first), content: source.slice(first, last), after: source.slice(last) }
}
export function citationDefinitions(source) {
  const lines = source.split("\n"), offsets = [0]
  lines.forEach(line => offsets.push(offsets.at(-1) + line.length + 1))
  return contentRanges(tokenizer.parse(source, {}), lines, offsets, source, true).map(range => {
    const text = source.slice(range.from, range.to)
    const match = /^ {0,3}\[\^[^\]]+\]:[ \t]*(.*?)(?:\r?\n|$)/.exec(text)
    const body = (match?.[1] || "") + "\n" + text.slice(match?.[0].length || 0).replace(/^ {4}|^\t/gm, "")
    return { label: range.label, body: body.trimEnd(), source: text, from: range.from, to: range.to }
  })
}
function signature(node) {
  const json = node.toJSON()
  if (json.attrs) json.attrs = Object.fromEntries(Object.entries(json.attrs).filter(([key]) => !["source", "snapshot"].includes(key)))
  return JSON.stringify(json)
}
function trailingParagraph() {
  const node = schema.nodes.paragraph.create()
  return node.type.create({ source: "", snapshot: signature(node) })
}
function needsTrailing(doc) {
  if (doc.lastChild?.type === schema.nodes.paragraph) return false
  let last
  doc.forEach(node => { if (node.type !== schema.nodes.preserved || node.attrs.source.trim()) last = node })
  return last?.type === schema.nodes.code_block || last?.type === schema.nodes.preserved
}
function ensureTrailing(doc) {
  return needsTrailing(doc) ? doc.copy(doc.content.append(Fragment.from(trailingParagraph()))) : doc
}
function moveBelowCode(state, dispatch) {
  const { $head, empty } = state.selection
  if (!empty || $head.parent.type !== schema.nodes.code_block || $head.parentOffset !== $head.parent.content.size) return false
  const position = $head.after()
  if (dispatch) {
    const tr = state.tr
    // Exact Markdown separators are preserved nodes between visible blocks.
    // Skip those and use the next text block before creating an escape line.
    const next = TextSelection.findFrom(state.doc.resolve(position), 1, true)
    if (next) tr.setSelection(next)
    else {
      tr.insert(position, trailingParagraph())
      tr.setSelection(TextSelection.near(tr.doc.resolve(position + 1)))
    }
    tr.scrollIntoView()
    dispatch(tr)
  }
  return true
}
function preserved(source, kind = null, label = null) { return schema.nodes.preserved.create({ source, kind, label }) }
export function parseDocument(markdown) {
  if (!markdown) return schema.topNodeType.createAndFill()
  const lines = markdown.split("\n")
  const offsets = [0]
  lines.forEach(line => offsets.push(offsets.at(-1) + line.length + 1))
  const tokens = defaultMarkdownParser.tokenizer.parse(markdown, {})
  const specials = contentRanges(tokens, lines, offsets, markdown)
  const blocks = []
  const segments = []
  let cursor = 0
  for (const special of specials) {
    if (special.from < cursor) continue
    if (special.from > cursor) segments.push({ source: markdown.slice(cursor, special.from) })
    segments.push({ ...special, source: markdown.slice(special.from, special.to) })
    cursor = special.to
  }
  if (cursor < markdown.length) segments.push({ source: markdown.slice(cursor) })
  for (const segment of segments) {
    if (segment.kind) { blocks.push(preserved(segment.source, segment.kind, segment.label)); continue }
    const source = segment.source
    const segmentLines = source.split("\n"), segmentOffsets = [0]
    segmentLines.forEach(line => segmentOffsets.push(segmentOffsets.at(-1) + line.length + 1))
    const ranges = tokenizer.parse(source, {}).filter(t => t.level === 0 && t.map && t.nesting !== -1)
    let consumed = 0
    for (const token of ranges) {
      const [from, to] = token.map
      const start = segmentOffsets[from], end = Math.min(segmentOffsets[to], source.length)
      if (start < consumed) continue
      if (start > consumed) blocks.push(preserved(source.slice(consumed, start)))
      const text = source.slice(start, end)
      try {
        const parsed = richMarkdownParser.parse(text)
        if (parsed.firstChild?.type.name !== "code_block" && /~~|\]\s*\[|\]\(mention:|<\/?[a-z!]|^\s*(?:>\s*)*(?:[-*+]|\d+[.)]) \[[ xX]\]|^\s*\[[^\]]+\]:|^:::(?: \{\.presentation.*\})?$/im.test(text)) throw new Error("preserve")
        if (parsed.childCount !== 1) throw new Error("preserve")
        let node = schema.nodeFromJSON(parsed.firstChild.toJSON())
        node = node.type.create({ ...node.attrs, source: text, snapshot: signature(node) }, node.content, node.marks)
        blocks.push(node)
      } catch { blocks.push(preserved(text, ["bullet_list_open", "ordered_list_open"].includes(token.type) ? "list" : null)) }
      consumed = end
    }
    if (consumed < source.length) blocks.push(preserved(source.slice(consumed)))
  }
  return ensureTrailing(schema.topNodeType.create(null, blocks.length ? blocks : schema.nodes.paragraph.create()))
}
export function serializeDocument(doc, recordRange = null) {
  let output = "", previousChanged = false
  doc.forEach((node, position) => {
    const unchanged = node.type.name === "preserved" || (node.attrs.source !== null && node.attrs.snapshot === signature(node))
    const source = unchanged ? node.attrs.source : defaultMarkdownSerializer.serialize(schema.topNodeType.create(null, node))
    // New/changed blocks need a block separator, including after an original
    // final paragraph with no trailing newline. Untouched boundaries stay exact.
    if (output && source.trim() && (!unchanged || previousChanged) && !output.endsWith("\n\n")) output += output.endsWith("\n") ? "\n" : "\n\n"
    const from = output.length
    output += source
    recordRange?.(position, { from, to: output.length })
    if (source.trim()) previousChanged = !unchanged
  })
  return output
}

// Align the editable characters in one rich block with its serialized source.
// Markdown punctuation exists only on the source side; matching characters
// keep a caret in the text even when headings, marks, links or fences surround it.
function blockSourceMap(node, position, source) {
  const chars = [], positions = []
  node.descendants((child, offset) => {
    if (child.isText) {
      for (let i = 0; i < child.text.length; i++) { chars.push(child.text[i]); positions.push(position + 1 + offset + i) }
    } else if (child.type.name === "hard_break") {
      chars.push("\n"); positions.push(position + 1 + offset)
    }
  })
  const sourcePositions = Array(chars.length).fill(null)
  if (!chars.length) return { positions, sourcePositions }
  const searchFrom = node.type.name === "code_block" ? source.indexOf("\n") + 1 : 0
  const contiguous = source.indexOf(chars.join(""), searchFrom)
  if (contiguous >= 0) {
    for (let i = 0; i < chars.length; i++) sourcePositions[i] = contiguous + i
    return { positions, sourcePositions }
  }
  let plain = 0, raw = 0
  for (const change of diffArrays(chars, source.split(""))) {
    if (change.added) raw += change.value.length
    else if (change.removed) plain += change.value.length
    else for (let i = 0; i < change.value.length; i++) sourcePositions[plain++] = raw++
  }
  return { positions, sourcePositions }
}

function sourceOffsetForRich(doc, position) {
  let selected = null
  const source = serializeDocument(doc, (blockPosition, range) => {
    const node = doc.nodeAt(blockPosition)
    if (position >= blockPosition && position <= blockPosition + node.nodeSize)
      selected = { node, blockPosition, range }
  })
  if (!selected) return position <= 0 ? 0 : source.length
  const { node, blockPosition, range } = selected
  const { positions, sourcePositions } = blockSourceMap(node, blockPosition, source.slice(range.from, range.to))
  if (!positions.length) return range.from
  const next = positions.findIndex(textPosition => textPosition >= position)
  if (next < 0) return range.from + (sourcePositions.at(-1) ?? range.to - range.from - 1) + 1
  const mapped = sourcePositions[next]
  if (mapped !== null) return range.from + mapped
  const following = sourcePositions.slice(next).find(value => value !== null)
  if (following !== undefined) return range.from + following
  const preceding = sourcePositions.slice(0, next).reverse().find(value => value !== null)
  return range.from + (preceding === undefined ? 0 : preceding + 1)
}

function richPositionForSource(doc, offset) {
  const blocks = []
  const source = serializeDocument(doc, (position, range) => blocks.push({ position, range }))
  if (!blocks.length) return 0
  const block = blocks.find(({ range }) => offset >= range.from && offset < range.to) ||
    blocks.find(({ range }) => range.from >= offset) || blocks.at(-1)
  const node = doc.nodeAt(block.position)
  const { positions, sourcePositions } = blockSourceMap(node, block.position, source.slice(block.range.from, block.range.to))
  if (!positions.length) return Math.min(doc.content.size, block.position + node.nodeSize)
  const within = Math.max(0, offset - block.range.from)
  const next = sourcePositions.findIndex(sourcePosition => sourcePosition !== null && sourcePosition >= within)
  return next < 0 ? positions.at(-1) + 1 : positions[next]
}

export function createRichDocument(element, markdown, changed, selectionChanged = () => {}, preview = null, comments = []) {
  let rangeDoc, ranges, previewOffsetTimer
  const sourceRangeAt = (view, position) => {
    if (rangeDoc !== view.state.doc) {
      ranges = new Map()
      serializeDocument(view.state.doc, (pos, range) => ranges.set(pos, range))
      rangeDoc = view.state.doc
    }
    if (ranges.has(position)) return ranges.get(position)
    const node = view.state.doc.nodeAt(position)
    if (node?.type !== schema.nodes.preserved) return null
    const source = serializeDocument(view.state.doc)
    const escaped = node.attrs.source.trim().split("\n").map(line => line.trim().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("\\n[ \\t]*(?:>[ \\t]*)*")
    let occurrence = 0
    view.state.doc.descendants((child, pos) => { if (pos < position && child.type === node.type && child.attrs.source.trim() === node.attrs.source.trim()) occurrence++ })
    const match = Array.from(source.matchAll(new RegExp(escaped, "g")))[occurrence]
    return match ? { from: match.index, to: match.index + match[0].length } : null
  }
  const state = EditorState.create({
    doc: parseDocument(markdown),
    plugins: [history(), codeHighlight(), commentPlugin(comments), new Plugin({ appendTransaction(transactions, oldState, state) {
      if (transactions.some(tr => tr.docChanged) && needsTrailing(state.doc))
        return state.tr.insert(state.doc.content.size, trailingParagraph()).setMeta("addToHistory", false)
    } }), keymap({
      "Mod-a": selectFocusedText, ...lineNavigation,
      "Mod-b": toggleMark(schema.marks.strong), "Mod-i": toggleMark(schema.marks.em),
      "Mod-z": undo, "Mod-Shift-z": redo, "Mod-y": redo,
      "Ctrl-b": toggleMark(schema.marks.strong), "Meta-b": toggleMark(schema.marks.strong),
      "Ctrl-i": toggleMark(schema.marks.em), "Meta-i": toggleMark(schema.marks.em),
      "Ctrl-z": undo, "Meta-z": undo, "Ctrl-Shift-z": redo, "Meta-Shift-z": redo, "Ctrl-y": redo,
      "Shift-Enter": chainCommands(codeNewline, (state, dispatch) => { if (dispatch) dispatch(state.tr.replaceSelectionWith(schema.nodes.hard_break.create()).scrollIntoView()); return true }),
      "Mod-Enter": exitCode, ArrowDown: moveBelowCode,
      "Mod-k": linkCommand, "Ctrl-k": linkCommand, "Meta-k": linkCommand,
      "Mod-Shift-7": wrapInList(schema.nodes.ordered_list), "Mod-Shift-8": wrapInList(schema.nodes.bullet_list),
      "Mod-Alt-0": setBlockType(schema.nodes.paragraph), "Mod-Alt-1": setBlockType(schema.nodes.heading, { level: 1 }),
      "Mod-Alt-2": setBlockType(schema.nodes.heading, { level: 2 }), "Mod-Alt-3": setBlockType(schema.nodes.heading, { level: 3 }),
      Enter: chainCommands(codeNewline, splitListItem(schema.nodes.list_item)), Tab: chainCommands(indentCode, sinkListItem(schema.nodes.list_item)),
      "Shift-Tab": liftListItem(schema.nodes.list_item)
    }), keymap(baseKeymap)]
  })
  const view = new EditorView(element, {
    state, nodeViews: {
      preserved: (node, view, getPos) => sourceNodeView(node, view, getPos, preview, sourceRangeAt),
      code_block: (node, view, getPos) => codeNodeView(node, view, getPos, preview, sourceRangeAt)
    }, attributes: { class: "markdown-rendered", role: "textbox", "aria-label": "Document body", "aria-multiline": "true" },
    handleDOMEvents: {
      copy(view, event) {
        const slice = view.state.selection.content()
        let hasSourceBlock = false
        slice.content.forEach(node => { if (node.type === schema.nodes.preserved || node.type === schema.nodes.code_block) hasSourceBlock = true })
        if (!hasSourceBlock || slice.openStart || slice.openEnd || !event.clipboardData) return false
        const source = serializeDocument(schema.topNodeType.create(null, slice.content))
        event.clipboardData.setData("text/plain", source)
        event.clipboardData.setData("application/x-coplan-markdown", source)
        event.preventDefault()
        return true
      }
    },
    handlePaste(view, event) {
      if (view.state.selection.$from.parent.type === schema.nodes.code_block) return false
      const source = event.clipboardData?.getData("application/x-coplan-markdown") || event.clipboardData?.getData("text/plain")
      if (!source || !/(^|\n)```[^\n]*\n|^\s*\|[^\n]+\|\s*\n\s*\|?\s*:?-{3,}/m.test(source)) return false
      const parsed = parseDocument(source)
      view.dispatch(view.state.tr.replaceSelection(new Slice(parsed.content, 0, 0)).scrollIntoView())
      return true
    },
    dispatchTransaction(transaction) {
      // Async decorations can redraw before selectionchange reaches the view.
      // Preserve the native caret instead of restoring a stale model selection.
      if (!transaction.docChanged && !transaction.selectionSet && view.hasFocus() && !view.composing) {
        const { $from, $to } = visibleSelection(view.state, view)
        if ($from.parent.inlineContent && $to.parent.inlineContent) {
          const selection = TextSelection.create(transaction.doc, $from.pos, $to.pos)
          if (!selection.eq(transaction.selection)) transaction.setSelection(selection)
        }
      }
      view.updateState(view.state.apply(transaction))
      if (transaction.docChanged) {
        clearTimeout(previewOffsetTimer)
        previewOffsetTimer = setTimeout(() => {
          for (const body of view.dom.querySelectorAll(".document-editor__block-preview[data-source-from]")) {
            body._coplanRefreshSourceRange?.()
          }
        }, 150)
        if (!transaction.getMeta("remote")) changed(serializeDocument(view.state.doc))
      }
      selectionChanged(toolbarState(view.state))
    }
  })
  return {
    view,
    content: () => serializeDocument(view.state.doc),
    sourceSelection() {
      const { $from, $to } = visibleSelection(view.state, view)
      return { from: sourceOffsetForRich(view.state.doc, $from.pos), to: sourceOffsetForRich(view.state.doc, $to.pos) }
    },
    selectSource(from, to = from) {
      const start = richPositionForSource(view.state.doc, from)
      const end = richPositionForSource(view.state.doc, to)
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, Math.min(start, end), Math.max(start, end))).scrollIntoView())
      view.focus()
    },
    toolbarState: () => toolbarState(view.state),
    historyState: () => ({ undo: undo(view.state), redo: redo(view.state) }),
    update(markdown) {
      if (serializeDocument(view.state.doc) === markdown) return
      const next = parseDocument(markdown)
      const transaction = view.state.tr
      patchChildren(transaction, view.state.doc, next, 0)
      // Remote steps map selection and existing undo events; they are never an
      // undoable user edit. Do not focus or scroll a background update.
      view.dispatch(transaction.setMeta("addToHistory", false).setMeta("remote", true))
    },
    destroy() { clearTimeout(previewOffsetTimer); view.destroy() },
    updateComments(next) {
      view.dispatch(view.state.tr.setMeta(commentKey, next).setMeta("addToHistory", false))
    },
    focusText(text, occurrence = 0) {
      const wanted = text?.replace(/\s+/g, " ").trim()
      let match = 0, position = null
      if (wanted) view.state.doc.descendants((node, pos) => {
        if (!node.isTextblock || node.type === schema.nodes.code_block) return
        if (node.textContent.replace(/\s+/g, " ").trim() !== wanted) return
        if (match++ === occurrence) { position = pos + 1; return false }
      })
      if (position !== null) view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(position))))
      view.dom.focus({ preventScroll: true })
      return position !== null
    },
    appendParagraph() {
      const tr = view.state.tr, last = tr.doc.lastChild
      const exists = last?.type === schema.nodes.paragraph && last.content.size === 0
      if (!exists) tr.insert(tr.doc.content.size, trailingParagraph())
      tr.setSelection(TextSelection.near(tr.doc.resolve(tr.doc.content.size - 1))).scrollIntoView()
      view.dispatch(tr); view.focus()
    },
    captureSelection() {
      // Read the native caret before a toolbar popover moves focus away. A
      // click's selectionchange may not have reached ProseMirror yet.
      const { $from, $to } = visibleSelection(view.state, view)
      if (!$from.parent.inlineContent || !$to.parent.inlineContent) return
      const selection = TextSelection.create(view.state.doc, $from.pos, $to.pos)
      if (!selection.eq(view.state.selection)) view.dispatch(view.state.tr.setSelection(selection))
    },
    insertCode(language = "") {
      const block = schema.nodes.code_block.create({ params: language })
      const tr = view.state.tr.replaceSelectionWith(block)
      // The default insertion selection may land in following prose. Locate
      // this new node (copies retain its attrs) and select its editable content.
      tr.doc.descendants((node, position) => {
        if (node.attrs === block.attrs) tr.setSelection(TextSelection.create(tr.doc, position + 1))
      })
      view.dispatch(tr.scrollIntoView()); view.focus()
    },
    deleteCode(position) {
      const node = view.state.doc.nodeAt(position)
      if (node?.type !== schema.nodes.code_block) return false
      const tr = closeHistory(view.state.tr.delete(position, position + node.nodeSize))
      tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(position, tr.doc.content.size))))
      view.dispatch(tr.scrollIntoView()); view.focus()
      return true
    },
    setLanguage(position, language) {
      const node = view.state.doc.nodeAt(position)
      if (node?.type !== schema.nodes.code_block || /[\r\n`]/.test(language)) return false
      view.dispatch(view.state.tr.setNodeMarkup(position, null, { ...node.attrs, params: language }))
      return true
    },
    deleteContentBlock(position) {
      const node = view.state.doc.nodeAt(position)
      if (node?.type !== schema.nodes.preserved) return false
      const tr = closeHistory(view.state.tr.delete(position, position + node.nodeSize))
      tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(position, tr.doc.content.size))))
      view.dispatch(tr); view.focus()
      return true
    },
    setBlockSource(position, source) {
      const node = view.state.doc.nodeAt(position)
      if (node?.type !== schema.nodes.preserved) return false
      view.dispatch(view.state.tr.setNodeMarkup(position, null, { ...node.attrs, source }))
      return true
    },
    replaceSource(from, to, source) {
      const current = serializeDocument(view.state.doc)
      const next = parseDocument(current.slice(0, from) + source + current.slice(to))
      const tr = view.state.tr
      patchChildren(tr, view.state.doc, next, 0)
      view.dispatch(tr)
    },
    sourceRange(position) { return sourceRangeAt(view, position) },
    command(name, value) {
      const commands = {
        bold: toggleMark(schema.marks.strong), italic: toggleMark(schema.marks.em),
        heading: setBlockType(schema.nodes.heading, { level: Number(value || 2) }), paragraph: setBlockType(schema.nodes.paragraph), code_block: setBlockType(schema.nodes.code_block),
        bullet: chainCommands(liftListItem(schema.nodes.list_item), wrapInList(schema.nodes.bullet_list)), ordered: chainCommands(liftListItem(schema.nodes.list_item), wrapInList(schema.nodes.ordered_list)),
        quote: chainCommands(lift, wrapIn(schema.nodes.blockquote)), code: toggleMark(schema.marks.code), undo, redo
      }
      commands.link = linkCommand
      commands[name]?.(view.state, view.dispatch, view)
      view.focus()
    }
  }
}

// Editor-owned decorations keep comment highlights out of ProseMirror's
// content DOM. Source cards contribute text to occurrence counting, but their
// rendered previews have no editable positions and get no decoration here.
function commentPlugin(initial) {
  let comments = initial
  return new Plugin({
    key: commentKey,
    state: {
      init: (_, state) => commentDecorations(state.doc, comments),
      apply(transaction, previous, _, state) {
        const incoming = transaction.getMeta(commentKey)
        if (incoming) comments = incoming
        if (incoming) return commentDecorations(state.doc, comments)
        if (!transaction.docChanged) return previous
        // Mapping the existing ranges is cheap even in a long document and
        // keeps a thread on its passage when text is inserted above it.
        // Keep a typed insertion or small replacement in the quoted passage
        // highlighted immediately, including a burst typed before autosave.
        // The server then resolves the durable source range on save. A broad
        // rewrite drops the provisional mark instead of moving it to another
        // copy of the same text elsewhere in the document.
        const mapped = previous.map(transaction.mapping, state.doc)
        const valid = mapped.find().flatMap(mark => {
          const before = mark.spec.expected
          const after = state.doc.textBetween(mark.from, mark.to)
          if (after === before) return [mark]
          if (!before || !after) return []
          let prefix = 0
          while (prefix < Math.min(before.length, after.length) && before[prefix] === after[prefix]) prefix++
          let suffix = 0
          while (suffix < Math.min(before.length, after.length) - prefix && before[before.length - suffix - 1] === after[after.length - suffix - 1]) suffix++
          const insertionInside = prefix > 0 && suffix > 0 && prefix + suffix === before.length && after.length > before.length
          const deletionInside = prefix > 0 && suffix > 0 && prefix + suffix === after.length &&
            after.length >= Math.max(3, Math.ceil(before.length * 0.3))
          const smallEdit = Math.abs(before.length - after.length) <= 8 &&
            Math.max(before.length - prefix - suffix, after.length - prefix - suffix) <= 8
          if (!insertionInside && !deletionInside && !smallEdit) return []
          return [Decoration.inline(mark.from, mark.to, mark.type.attrs, { ...mark.spec, expected: after })]
        })
        return DecorationSet.create(state.doc, valid)
      }
    },
    props: { decorations(state) { return commentKey.getState(state) } }
  })
}

function commentDecorations(doc, comments) {
  if (!comments.length) return DecorationSet.empty
  const chars = [], positions = []
  const add = (text, start = null) => {
    for (let i = 0; i < text.length; i++) {
      chars.push(text[i]); positions.push(start === null ? null : start + i)
    }
  }
  doc.descendants((node, position) => {
    if (node.isTextblock && chars.length) add(" ")
    if (node.isText) add(node.text, position)
    else if (node.type.name === "preserved") add(node.attrs.source.replace(/^\s*\|?\s*:?-{3,}.*$/gm, "").replace(/\|/g, " "))
  })
  let folded = "", foldedPositions = []
  chars.forEach((char, i) => {
    if (/\s/.test(char)) {
      if (folded.endsWith(" ")) return
      folded += " "; foldedPositions.push(positions[i])
    } else { folded += char; foldedPositions.push(positions[i]) }
  })
  const decorations = []
  for (const comment of comments) {
    const needle = comment.text.replace(/\s+/g, " ").trim()
    if (!needle) continue
    let offset = -1
    for (let i = 0; i <= comment.occurrence; i++) {
      offset = folded.indexOf(needle, offset + 1)
      if (offset < 0) break
    }
    if (offset < 0) continue
    let start = null, end = null
    const emit = () => {
      if (start === null) return
      decorations.push(Decoration.inline(start, end, {
        nodeName: "mark", class: `anchor-highlight anchor-highlight--${comment.status}`,
        "data-thread-id": comment.id,
        "data-action": "click->coplan--text-selection#openEditorThread"
      }, { expected: doc.textBetween(start, end) }))
    }
    for (let i = offset; i < offset + needle.length; i++) {
      const position = foldedPositions[i]
      if (position === null || position === undefined || position !== end) { emit(); start = position; end = position === null ? null : position + 1 }
      else end++
    }
    emit()
  }
  return DecorationSet.create(doc, decorations)
}

function toolbarState(state) {
  const { from, to, empty, $from } = state.selection
  const marks = state.storedMarks || $from.marks()
  const markActive = name => empty ? !!schema.marks[name].isInSet(marks) : state.doc.rangeHasMark(from, to, schema.marks[name])
  const ancestor = name => { for (let depth = $from.depth; depth > 0; depth--) if ($from.node(depth).type.name === name) return $from.node(depth); return null }
  return { bold: markActive("strong"), italic: markActive("em"), code: markActive("code"), link: markActive("link"),
    bullet: !!ancestor("bullet_list"), ordered: !!ancestor("ordered_list"), quote: !!ancestor("blockquote"),
    heading: ancestor("code_block") ? "code" : ancestor("heading")?.attrs.level || 0, undo: undo(state), redo: redo(state) }
}

// Compare semantic content without the lossless-serialization bookkeeping.
function semantic(node) {
  if (node.type.name === "preserved") return JSON.stringify(node.toJSON())
  return JSON.stringify(node.toJSON(), (key, value) => ["source", "snapshot"].includes(key) ? undefined : value)
}
function patchChildren(tr, before, after, offset) {
  const oldChildren = [], newChildren = []
  before.forEach(node => oldChildren.push(node)); after.forEach(node => newChildren.push(node))
  // Text-node boundaries change when marks change. Diff the characters first
  // so a remote bold/link edit cannot replace (and erase undo for) local text.
  if (before.isTextblock && after.isTextblock && [...oldChildren, ...newChildren].every(node => node.isText)) {
    for (const hunk of textHunks(before.textContent, after.textContent).reverse()) {
      tr.replaceWith(offset + hunk.from, offset + hunk.to, hunk.text ? schema.text(hunk.text) : Fragment.empty)
    }
    if (after.content.size) {
      tr.removeMark(offset, offset + after.content.size)
      let position = offset
      after.forEach(node => {
        for (const mark of node.marks) tr.addMark(position, position + node.nodeSize, mark)
        position += node.nodeSize
      })
    }
    return
  }
  let cursor = offset, pending = null, oldIndex = 0, newIndex = 0
  const edits = []
  for (const part of diffArrays(oldChildren, newChildren, { comparator: (a, b) => semantic(a) === semantic(b) })) {
    if (!part.added && !part.removed) {
      if (pending) edits.push(pending)
      pending = null
      // Keep source spelling changes even if the parsed content is identical.
      for (let i = 0; i < part.value.length; i++) {
        const old = oldChildren[oldIndex++], next = newChildren[newIndex++]
        if (!old.eq(next)) edits.push({ from: cursor, to: cursor + old.nodeSize, old: [old], nodes: [next] })
        cursor += old.nodeSize
      }
    } else {
      pending ||= { from: cursor, to: cursor, old: [], nodes: [] }
      if (part.removed) { oldIndex += part.value.length; pending.old.push(...part.value); cursor += part.value.reduce((n, node) => n + node.nodeSize, 0); pending.to = cursor }
      else { newIndex += part.value.length; pending.nodes.push(...part.value) }
    }
  }
  if (pending) edits.push(pending)
  for (const edit of edits.reverse()) {
    const old = edit.old[0], next = edit.nodes[0]
    if (edit.old.length === 1 && edit.nodes.length === 1 && old.type === next.type && old.sameMarkup(next)) {
      if (old.isText) {
        for (const hunk of textHunks(old.text, next.text).reverse()) {
          tr.replaceWith(edit.from + hunk.from, edit.from + hunk.to, hunk.text ? schema.text(hunk.text, next.marks) : Fragment.empty)
        }
      } else if (!old.isLeaf) patchChildren(tr, old, next, edit.from + 1)
      else tr.replaceWith(edit.from, edit.to, next)
    } else if (edit.old.length === 1 && edit.nodes.length === 1 && old.type === next.type && !old.isLeaf && !old.isText ) {
      patchChildren(tr, old, next, edit.from + 1)
      tr.setNodeMarkup(edit.from, next.type, next.attrs, next.marks)
    } else tr.replaceWith(edit.from, edit.to, Fragment.fromArray(edit.nodes))
  }
}

// A code box is its own text selection scope. ProseMirror's selectAll
// selects the entire document, including every other code/prose block.
function visibleSelection(state, view) {
  let { $from, $to } = state.selection
  // A native click can precede ProseMirror's asynchronous selectionchange.
  // Scope this shortcut to the visible caret, including decorated token nodes.
  const selection = view.dom.ownerDocument.getSelection()
  if (selection?.anchorNode && view.dom.contains(selection.anchorNode) && view.dom.contains(selection.focusNode)) {
    $from = state.doc.resolve(view.posAtDOM(selection.anchorNode, selection.anchorOffset))
    $to = state.doc.resolve(view.posAtDOM(selection.focusNode, selection.focusOffset))
  }
  return { $from, $to }
}
function selectFocusedText(state, dispatch, view) {
  const { $from, $to } = visibleSelection(state, view)
  if ($from.sameParent($to) && $from.parent.type === schema.nodes.code_block) {
    if (dispatch) dispatch(state.tr.setSelection(TextSelection.create(state.doc, $from.start(), $from.end())))
    return true
  }
  return selectAll(state, dispatch)
}

// On macOS Control+A means the current line, not the entire multiline block.
function codeLineStart(state, dispatch, view) {
  const { $to } = visibleSelection(state, view)
  if (!$to.parent.type.spec.code) return false
  const before = $to.parent.textContent.slice(0, $to.parentOffset)
  const position = $to.start() + before.lastIndexOf("\n") + 1
  if (dispatch) dispatch(state.tr.setSelection(TextSelection.create(state.doc, position)).scrollIntoView())
  return true
}
function codeNewline(state, dispatch) {
  const { $from, $to } = state.selection
  if (!$from.sameParent($to) || !$from.parent.type.spec.code) return false
  const line = $from.parent.textBetween(0, $from.parentOffset).split("\n").at(-1)
  const indent = line.match(/^[ \t]*/)[0]
  if (dispatch) dispatch(state.tr.insertText("\n" + indent).scrollIntoView())
  return true
}
function indentCode(state, dispatch) {
  if (!state.selection.$from.parent.type.spec.code) return false
  if (dispatch) dispatch(state.tr.insertText("  ").scrollIntoView())
  return true
}

function linkCommand(state, dispatch) {
  const href = window.prompt("Link URL (https://…)")
  if (href && /^(https?:\/\/|mailto:)/i.test(href)) toggleMark(schema.marks.link, { href })(state, dispatch)
  return true
}

// Node-view chrome uses the form's Stimulus actions. The editable code content
// remains owned by ProseMirror; preview DOM is an isolated, non-editable sibling.
function blockChrome(getPos, label) {
  const dom = document.createElement("div"); dom.className = "document-editor__block"
  dom.coplanPosition = getPos
  const header = document.createElement("div"); header.className = "document-editor__block-header"; header.contentEditable = "false"
  const title = document.createElement("span"); title.textContent = label
  const edit = document.createElement("button"); edit.type = "button"; edit.textContent = "Edit Markdown"
  edit.dataset.action = "coplan--editor#editSource"
  const copy = document.createElement("button"); copy.type = "button"; copy.textContent = "Copy"
  copy.setAttribute("aria-label", "Copy block as Markdown")
  copy.dataset.action = "coplan--editor#copyBlock"
  header.append(title, edit, copy); dom.append(header)
  return { dom, header, title, edit, copy }
}
function previewSettled(body, view, getPos, sourceRangeAt) {
  const updateRange = (force = false) => {
    const range = sourceRangeAt(view, getPos())
    if (!range) return
    if (!force && body.dataset.sourceFrom === String(range.from) && body.dataset.sourceTo === String(range.to)) return
    body.dataset.sourceFrom = range.from
    body.dataset.sourceTo = range.to
    body.dispatchEvent(new CustomEvent("coplan:editor-preview-settled", { bubbles: true }))
  }
  body._coplanRefreshSourceRange = () => updateRange()
  updateRange(true)
}

function sourceNodeView(initial, view, getPos, preview, sourceRangeAt) {
  let node = initial, generation = 0
  const { dom, title, edit, copy } = blockChrome(getPos, "Markdown block")
  if (node.attrs.kind === "reference") {
    dom.hidden = true
    return { dom, update: next => next.type === node.type && next.attrs.kind === "reference",
      stopEvent: () => true, ignoreMutation: () => true }
  }
  if (["presentation", "iframe"].includes(node.attrs.kind)) {
    dom.classList.add("document-editor__content-block")
    dom.contentEditable = "false"
    title.textContent = node.attrs.kind === "presentation" ? "Presentation" : "Embedded page"
    edit.remove()
    const remove = document.createElement("button"); remove.type = "button"; remove.textContent = "×"
    remove.setAttribute("aria-label", node.attrs.kind === "presentation" ? "Remove presentation" : "Remove embedded page")
    remove.dataset.action = "coplan--editor#deleteContentBlock"
    dom.querySelector(".document-editor__block-header").append(remove)
    if (node.attrs.kind === "presentation") {
      title.className = "document-editor__presentation-label"
      const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      icon.setAttribute("viewBox", "0 0 24 24"); icon.setAttribute("aria-hidden", "true")
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
      path.setAttribute("d", "M3 3h18v13H3z M12 16v5 M8 21h8 M7 7h10 M7 11h6")
      icon.append(path); title.prepend(icon)
      const toggle = document.createElement("button"); toggle.type = "button"; toggle.textContent = "Preview"
      toggle.dataset.action = "coplan--editor#togglePresentationPreview"
      toggle.setAttribute("aria-expanded", "false")
      dom.querySelector(".document-editor__block-header").insertBefore(toggle, copy)
      const body = document.createElement("div"); body.className = "document-editor__block-preview"; body.hidden = true
      const input = document.createElement("textarea")
      input.className = "document-editor__block-source"
      input.setAttribute("aria-label", "Presentation Markdown")
      input.dataset.action = "input->coplan--editor#blockSourceChanged keydown->coplan--editor#blockKeydown"
      input.value = presentationContent(node.attrs.source).content
      dom.append(input, body)
      const renderPreview = async () => {
        const sequence = ++generation
        body.textContent = "Loading preview…"; body.setAttribute("aria-busy", "true")
        try {
          const definitions = []
          view.state.doc.descendants(item => {
            if (item.attrs.kind === "reference") definitions.push(item.attrs.source)
          })
          const html = await preview([node.attrs.source, ...definitions].join("\n\n"))
          if (sequence === generation) body.innerHTML = html
        } catch {
          if (sequence === generation) body.textContent = "Preview unavailable. Return to Markdown to keep editing."
        } finally {
          if (sequence === generation) body.removeAttribute("aria-busy")
        }
      }
      dom.coplanTogglePreview = () => {
        const showing = body.hidden
        toggle.setAttribute("aria-expanded", String(showing))
        toggle.textContent = showing ? "Edit Markdown" : "Preview"
        input.hidden = showing; body.hidden = !showing
        if (showing) return renderPreview()
        generation++; body.removeAttribute("aria-busy")
        input.focus({ preventScroll: true })
      }
      return { dom, update(next) {
        if (next.type !== node.type || next.attrs.kind !== "presentation") return false
        const changed = next.attrs.source !== node.attrs.source
        node = next
        const content = presentationContent(node.attrs.source).content
        if (input.value !== content) {
          const start = input.selectionStart, end = input.selectionEnd
          input.value = content
          input.setSelectionRange(Math.min(start, content.length), Math.min(end, content.length))
        }
        if (changed && !body.hidden) renderPreview()
        return true
      }, stopEvent: () => true, ignoreMutation: () => true, destroy() { generation++ } }
    }
    copy.remove()
    const fields = document.createElement("div"); fields.className = "document-editor__embed-fields"
    const attrs = parseIframeSource(node.attrs.source)
    for (const [name, label, fallback] of [["src", "URL", ""], ["title", "Title", "Embedded content"], ["width", "Width", "100%"], ["height", "Height", "480"]]) {
      const wrapper = document.createElement("label"); wrapper.textContent = label
      const input = document.createElement("input"); input.value = attrs[name] || fallback
      input.dataset.embedAttribute = name
      input.dataset.action = "input->coplan--editor#embedChanged keydown->coplan--editor#blockKeydown"
      input.setAttribute("aria-label", `Embedded page ${name === "src" ? "URL" : label.toLowerCase()}`)
      if (name === "src") input.inputMode = "url"
      wrapper.append(input); fields.append(wrapper)
    }
    const previewBody = document.createElement("div"); previewBody.className = "document-editor__block-preview"
    const hint = document.createElement("p"); hint.className = "document-editor__embed-hint"
    const form = view.dom.closest("[data-coplan--editor-embed-domains-value]")
    const hosts = JSON.parse(form?.dataset.coplanEditorEmbedDomainsValue || form?.getAttribute("data-coplan--editor-embed-domains-value") || "[]")
    hint.textContent = (hosts.length ? `Approved domains: ${hosts.join(", ")}. HTTPS only.` : "No iframe domains are approved. An administrator can add them in CoPlan Admin.") + " Title describes the page for screen readers; it is not a visible caption."
    dom.append(fields, hint, previewBody)
    let previewTimer
    const render = () => {
      clearTimeout(previewTimer)
      const sequence = ++generation, source = node.attrs.source
      previewTimer = setTimeout(async () => {
        try { const html = await preview?.(source); if (html && sequence === generation) previewBody.innerHTML = html }
        catch { if (sequence === generation) previewBody.textContent = "Preview unavailable" }
      }, 300)
    }
    render()
    return { dom, update(next) {
      if (next.type !== node.type || next.attrs.kind !== "iframe") return false
      node = next
      const attrs = parseIframeSource(node.attrs.source)
      fields.querySelectorAll("input").forEach(input => { const value = attrs[input.dataset.embedAttribute] || ""; if (input.value !== value) input.value = value })
      render(); return true
    }, stopEvent: () => true, ignoreMutation: () => true, destroy() { generation++; clearTimeout(previewTimer) } }
  }

  dom.contentEditable = "false"
  if (node.attrs.kind === "table") {
    edit.textContent = "Edit table"
    edit.dataset.action = "coplan--editor#toggleBlockSource"
    const input = document.createElement("textarea"); input.className = "document-editor__block-source"
    input.setAttribute("aria-label", "Table Markdown"); input.hidden = true; input.value = node.attrs.source
    input.dataset.action = "input->coplan--editor#blockSourceChanged keydown->coplan--editor#blockKeydown"
    dom.append(input)
  }
  const body = document.createElement("div"); body.className = "document-editor__block-preview"; dom.append(body)
  const render = async () => {
    const sequence = ++generation, source = node.attrs.source
    dom.hidden = !source.trim()
    if (dom.hidden) return
    const isTable = node.attrs.kind !== "list" && /^\s*\|?.*\|.*\n\s*\|?\s*:?-{3,}/m.test(source)
    const isReferences = /^\s*\[\^[^\]]+\]:/m.test(source)
    title.textContent = node.attrs.kind === "list" ? "List" : isTable ? "Table" : isReferences ? "References" : "Markdown block"
    body.replaceChildren()
    const fallback = document.createElement("pre"); fallback.textContent = source; body.append(fallback)
    // Rendering definitions alone drops them as unused footnotes. Keep their
    // source visible so References cards never become empty previews.
    if (preview && !isReferences) {
      try {
        const html = await preview(source)
        if (sequence === generation) { body.innerHTML = html; previewSettled(body, view, getPos, sourceRangeAt) }
      } catch { /* Source remains usable offline. */ }
    }
  }
  render()
  return { dom, update(next) { if (next.type !== node.type || next.attrs.kind !== node.attrs.kind) return false; if (next.attrs.source !== node.attrs.source) {
      node = next
      const input = dom.querySelector("textarea")
      if (input && input.value !== node.attrs.source) input.value = node.attrs.source
      render()
    } return true },
    stopEvent: () => true, ignoreMutation: () => true, destroy() { generation++ } }
}
function codeNodeView(initial, view, getPos, preview, sourceRangeAt) {
  let node = initial, generation = 0, timer
  const { dom, header, title, edit } = blockChrome(getPos, "Code")
  dom.classList.add("document-editor__code-window")
  const controls = document.createElement("div"); controls.className = "document-editor__window-controls"
  const remove = document.createElement("button"); remove.type = "button"; remove.className = "document-editor__window-close"
  remove.setAttribute("aria-label", "Delete code block"); remove.title = "Delete code block"; remove.textContent = "×"
  remove.dataset.action = "coplan--editor#deleteCode"
  controls.append(remove)
  for (const color of ["yellow", "green"]) {
    const dot = document.createElement("span"); dot.className = `document-editor__window-dot document-editor__window-dot--${color}`
    dot.setAttribute("aria-hidden", "true"); controls.append(dot)
  }
  const language = document.createElement("input"); language.type = "text"; language.className = "document-editor__code-language"
  language.setAttribute("aria-label", "Code language"); language.placeholder = "Plain text"; language.setAttribute("list", "coplan-code-languages")
  language.dataset.action = "input->coplan--editor#languageInput change->coplan--editor#languageChanged"
  title.replaceWith(controls, language)
  const pre = document.createElement("pre"), contentDOM = document.createElement("code"); pre.append(contentDOM); dom.append(pre)
  const diagram = document.createElement("div"); diagram.className = "document-editor__block-preview"; diagram.contentEditable = "false"; dom.append(diagram)
  const render = (languageChanged = true) => {
    if (languageChanged && language.value !== (node.attrs.params || "")) language.value = node.attrs.params || ""
    const sequence = ++generation, mermaid = node.attrs.params?.trim().split(/\s+/)[0] === "mermaid"
    clearTimeout(timer)
    edit.hidden = true
    diagram.hidden = !mermaid
    if (!mermaid) { diagram.replaceChildren(); return }
    if (!preview) return
    timer = setTimeout(async () => {
      try {
        const html = await preview(defaultMarkdownSerializer.serialize(schema.topNodeType.create(null, node)))
        if (sequence === generation) { diagram.innerHTML = html; previewSettled(diagram, view, getPos, sourceRangeAt) }
      } catch { if (sequence === generation) diagram.textContent = "Preview unavailable. Your Mermaid source is retained." }
    }, 250)
  }
  render()
  return { dom, contentDOM, update(next) { if (next.type !== node.type) return false; const changed = !node.eq(next), languageChanged = node.attrs.params !== next.attrs.params; node = next; if (changed) render(languageChanged); return true },
    stopEvent: event => header.contains(event.target) || diagram.contains(event.target),
    ignoreMutation: mutation => mutation.type !== "selection" && !contentDOM.contains(mutation.target) && mutation.target !== contentDOM,
    destroy() { clearTimeout(timer); generation++ } }
}

// A source editor with no Markdown interpretation. Its history and selection
// map through incoming character edits, just like the rich editor's history.
export function createMarkdownDocument(element, source, changed) {
  const rawSchema = new Schema({ nodes: {
    doc: { content: "code_block" },
    code_block: { content: "text*", code: true, marks: "", toDOM: () => ["pre", ["code", 0]] }, text: {}
  } })
  const rawDoc = text => rawSchema.node("doc", null, rawSchema.node("code_block", null, text ? rawSchema.text(text) : null))
  const state = EditorState.create({ doc: rawDoc(source), plugins: [history(), keymap({
    "Mod-a": selectAll, ...lineNavigation,
    "Mod-z": undo, "Mod-Shift-z": redo, "Mod-y": redo,
    "Ctrl-z": undo, "Meta-z": undo, "Ctrl-Shift-z": redo, "Meta-Shift-z": redo, "Ctrl-y": redo,
    Tab: (state, dispatch) => { dispatch(state.tr.insertText("  ")); return true }
  }), keymap(baseKeymap)] })
  const view = new EditorView(element, { state, attributes: { role: "textbox", "aria-label": "Markdown source", "aria-multiline": "true", spellcheck: "false" },
    handlePaste(view, event) {
      const text = event.clipboardData?.getData("text/plain")
      if (text === undefined) return false
      view.dispatch(view.state.tr.insertText(text)); return true
    },
    clipboardTextSerializer: slice => slice.content.textBetween(0, slice.content.size, "\n"),
    dispatchTransaction(tr) { view.updateState(view.state.apply(tr)); if (tr.docChanged && !tr.getMeta("remote")) changed(view.state.doc.textContent) }
  })
  return { view, content: () => view.state.doc.textContent, destroy: () => view.destroy(),
    sourceSelection() {
      const { $from, $to } = visibleSelection(view.state, view)
      return { from: $from.pos - 1, to: $to.pos - 1 }
    },
    historyState: () => ({ undo: undo(view.state), redo: redo(view.state) }),
    command(name) { ({ undo, redo })[name]?.(view.state, view.dispatch); view.focus() },
    select(from, to = from) { view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, Math.min(from + 1, view.state.doc.content.size - 1), Math.min(to + 1, view.state.doc.content.size - 1))).scrollIntoView()); view.focus() },
    update(text) {
      const tr = view.state.tr
      for (const hunk of textHunks(view.state.doc.textContent, text).reverse()) tr.insertText(hunk.text, hunk.from + 1, hunk.to + 1)
      if (tr.docChanged) view.dispatch(tr.setMeta("remote", true).setMeta("addToHistory", false))
    }
  }
}

export function parseIframeSource(source) {
  const attrs = {}
  for (const match of source.matchAll(/([a-z]+)="([^"]*)"/g)) {
    const decoder = document.createElement("textarea"); decoder.innerHTML = match[2]
    attrs[match[1]] = decoder.value
  }
  return attrs
}
export function iframeSource(attrs) {
  const escape = value => String(value).replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;")
  return `::: {.iframe ${["src", "title", "width", "height"].map(name => `${name}="${escape(attrs[name])}"`).join(" ")} /}\n`
}
