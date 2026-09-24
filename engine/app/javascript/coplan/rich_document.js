import { diffArrays } from "diff"
import { codeHighlight } from "coplan/code_highlight"
import { textHunks } from "coplan/merge_text"
import { Schema, Fragment, Slice } from "prosemirror-model"
import { EditorState, TextSelection, Plugin, PluginKey } from "prosemirror-state"
import { EditorView, Decoration, DecorationSet } from "prosemirror-view"
import { defaultMarkdownParser, defaultMarkdownSerializer } from "prosemirror-markdown"
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
  group: "block", atom: true, attrs: { source: {} },
  toDOM: node => ["div", { class: "document-editor__preserved", hidden: node.attrs.source.trim() ? null : "hidden", contenteditable: "false" },
    ["small", "Preserved Markdown block"], ["pre", node.attrs.source]]
})
const schema = new Schema({ nodes, marks: defaultMarkdownParser.schema.spec.marks })
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
function preserved(source) { return schema.nodes.preserved.create({ source }) }
export function parseDocument(markdown) {
  if (!markdown) return schema.topNodeType.createAndFill()
  const lines = markdown.split("\n")
  const offsets = [0]
  lines.forEach(line => offsets.push(offsets.at(-1) + line.length + 1))
  const tokens = defaultMarkdownParser.tokenizer.parse(markdown, {})
  const ranges = tokens.filter(t => t.level === 0 && t.map && t.nesting !== -1).map(t => t.map)
  const blocks = []
  let cursor = 0
  for (const [from, to] of ranges) {
    const start = offsets[from], end = Math.min(offsets[to], markdown.length)
    if (start < cursor) continue
    if (start > cursor) blocks.push(preserved(markdown.slice(cursor, start)))
    const source = markdown.slice(start, end)
    try {
      // Raw HTML, tables, task lists, footnotes and reference definitions are
      // preserved until dedicated rich node views exist for them.
      const parsed = defaultMarkdownParser.parse(source)
      if (parsed.firstChild?.type.name !== "code_block" && /~~|\]\s*\[|\]\(mention:|<\/?[a-z!]|^\s*\|.*\||^\s*\|?\s*:?-{3,}.*\||^\s*(?:>\s*)*(?:[-*+]|\d+[.)]) \[[ xX]\]|^\s*\[[^\]]+\]:|\[\^[^\]]+\]/im.test(source)) throw new Error("preserve")
      if (parsed.childCount !== 1) throw new Error("preserve")
      let node = schema.nodeFromJSON(parsed.firstChild.toJSON())
      node = node.type.create({ ...node.attrs, source, snapshot: signature(node) }, node.content, node.marks)
      blocks.push(node)
    } catch { blocks.push(preserved(source)) }
    cursor = end
  }
  if (cursor < markdown.length) blocks.push(preserved(markdown.slice(cursor)))
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
    return ranges.get(position)
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
    sourceRange(position) {
      let result = null
      serializeDocument(view.state.doc, (pos, range) => { if (pos === position) result = range })
      return result
    },
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
        "data-action": "click->coplan--text-selection#openEditorThread mouseenter->coplan--text-selection#editorThreadEnter mouseleave->coplan--text-selection#editorThreadLeave"
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
  const { dom, title } = blockChrome(getPos, "Markdown block")
  dom.contentEditable = "false"
  const body = document.createElement("div"); body.className = "document-editor__block-preview"; dom.append(body)
  const render = async () => {
    const sequence = ++generation, source = node.attrs.source
    dom.hidden = !source.trim()
    if (dom.hidden) return
    const isTable = /^\s*\|?.*\|.*\n\s*\|?\s*:?-{3,}/m.test(source)
    title.textContent = isTable ? "Table" : "Markdown block"
    body.replaceChildren()
    const fallback = document.createElement("pre"); fallback.textContent = source; body.append(fallback)
    if (preview) {
      try {
        const html = await preview(source)
        if (sequence === generation) { body.innerHTML = html; previewSettled(body, view, getPos, sourceRangeAt) }
      } catch { /* Source remains usable offline. */ }
    }
  }
  render()
  return { dom, update(next) { if (next.type !== node.type) return false; if (next.attrs.source !== node.attrs.source) { node = next; render() } return true },
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
