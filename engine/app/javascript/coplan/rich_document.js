import { diffArrays } from "diff"
import { codeHighlight } from "coplan/code_highlight"
import { textHunks } from "coplan/merge_text"
import { citationLabelKey } from "coplan/citation_labels"
export { citationLabelKey } from "coplan/citation_labels"
import { Schema, Fragment, Slice, DOMSerializer } from "prosemirror-model"
import { EditorState, TextSelection, Plugin, PluginKey } from "prosemirror-state"
import { EditorView, Decoration, DecorationSet } from "prosemirror-view"
import { MarkdownParser, MarkdownSerializer, defaultMarkdownParser, defaultMarkdownSerializer as baseMarkdownSerializer } from "prosemirror-markdown"
import { baseKeymap, toggleMark, setBlockType, wrapIn, lift, chainCommands, exitCode, selectAll } from "prosemirror-commands"
import { wrapInList, splitListItem, liftListItem, sinkListItem } from "prosemirror-schema-list"
import { keymap } from "prosemirror-keymap"
import { history, undo, redo, closeHistory } from "prosemirror-history"
import { inputRules, wrappingInputRule, undoInputRule } from "prosemirror-inputrules"

const mac = /Mac|iP(hone|ad|od)/.test(navigator.platform)
const lineNavigation = mac ? { "Ctrl-a": codeLineStart } : {}
const commentKey = new PluginKey("coplan-comments")

// Preserve the exact source of untouched top-level blocks. Constructs outside
// the rich schema are atomic source cards, never silently parsed away.
let nodes = defaultMarkdownParser.schema.spec.nodes
nodes.forEach((name, spec) => {
  if (name !== "text") nodes = nodes.update(name, { ...spec, attrs: { ...spec.attrs, source: { default: null }, snapshot: { default: null } } })
})
const listItemSpec = nodes.get("list_item")
nodes = nodes.update("list_item", {
  ...listItemSpec,
  attrs: { ...listItemSpec.attrs, checked: { default: null } },
  parseDOM: [{ tag: "li[data-coplan-task]", getAttrs: dom => ({ checked: dom.dataset.coplanTask === "true" }) }, ...listItemSpec.parseDOM],
  toDOM: node => node.attrs.checked === null ? listItemSpec.toDOM(node) :
    ["li", { class: "document-editor__task", "data-coplan-task": String(node.attrs.checked) },
      ["span", { contenteditable: "false" }, ["input", { type: "checkbox", checked: node.attrs.checked ? "checked" : null,
        "data-coplan-task-checkbox": "", "aria-label": `Task: ${node.firstChild.textContent}` }]],
      ["div", { class: "document-editor__task-content" }, 0]]
})
nodes = nodes.addBefore("paragraph", "preserved", {
  group: "block", atom: true, attrs: { source: {}, kind: { default: null }, label: { default: null }, inserted: { default: false } },
  toDOM: node => ["div", { class: "document-editor__preserved", hidden: node.attrs.source.trim() ? null : "hidden", contenteditable: "false" },
    ["small", "Preserved Markdown block"], ["pre", node.attrs.source]]
})
nodes = nodes.addBefore("text", "footnote_reference", {
  inline: true, group: "inline", atom: true, attrs: { label: {} },
  leafText: node => `[^${node.attrs.label}]`,
  parseDOM: [{ tag: "sup[data-coplan-footnote]", getAttrs: dom => ({ label: dom.dataset.coplanFootnote }) }],
  toDOM: node => ["sup", { "data-coplan-footnote": node.attrs.label, class: "document-editor__footnote", title: `Reference: ${node.attrs.label}`, contenteditable: "false" }, ["button", { type: "button", "data-citation-label": node.attrs.label, "data-action": "coplan--editor#openCitation", "aria-label": `Edit citation ${node.attrs.label}` }, `[${node.attrs.label}]`]]
})
const imageSpec = nodes.get("image")
nodes = nodes.update("image", { ...imageSpec,
  attrs: { ...imageSpec.attrs, width: { default: null } },
  parseDOM: [{ tag: "img[src]", getAttrs: dom => ({ src: dom.getAttribute("src"), alt: dom.getAttribute("alt"), title: dom.getAttribute("title"), width: imageWidth(dom.getAttribute("width")) }) }],
  toDOM: node => ["img", { src: node.attrs.src, alt: node.attrs.alt, title: node.attrs.title, width: node.attrs.width }]
})
nodes = nodes.addBefore("paragraph", "template_note", {
  group: "block", content: "text*", marks: "", code: true, defining: true, isolating: true,
  attrs: { source: { default: null }, snapshot: { default: null }, opening: {}, closing: {} },
  toDOM: () => ["div", { class: "document-editor__template-note", "data-coplan-template-note": "", "aria-label": "Comment" }, 0]
})
const schema = new Schema({ nodes, marks: defaultMarkdownParser.schema.spec.marks.addToEnd("strikethrough", {
  parseDOM: [{ tag: "s" }, { tag: "del" }], toDOM: () => ["s", 0]
}) })
const tokenizer = defaultMarkdownParser.tokenizer
// The width syntax is an HTML image in otherwise ordinary Markdown. Parse
// only this tag; all other authored HTML keeps its source-card protection.
const imageTag = /<img\b(?:[^>"']|"[^"]*"|'[^']*')*>/gi
function imageWidth(value) { const width = Number(value); return /^\d+$/.test(value) && Number.isSafeInteger(width) && width > 0 ? width : null }
function htmlImage(source) {
  const template = document.createElement("template"); template.innerHTML = source
  const image = template.content.firstElementChild
  if (image?.tagName !== "IMG" || !image.hasAttribute("src") || !tokenizer.validateLink(image.getAttribute("src"))) return null
  // Unknown attributes must remain exact, including when nearby prose changes.
  if ([...image.attributes].some(attr => !["src", "alt", "title", "width"].includes(attr.name))) return null
  if (image.hasAttribute("width") && !imageWidth(image.getAttribute("width"))) return null
  return { src: image.getAttribute("src"), alt: image.getAttribute("alt") || "", title: image.getAttribute("title"), width: imageWidth(image.getAttribute("width")) }
}
tokenizer.inline.ruler.before("autolink", "coplan_image", (state, silent) => {
  if (state.src[state.pos] !== "<") return false
  const match = state.src.slice(state.pos).match(/^<img\b(?:[^>"']|"[^"]*"|'[^']*')*>/i)
  const attrs = match && htmlImage(match[0])
  if (!attrs) return false
  if (!silent) {
    const token = state.push("image", "img", 0)
    token.attrs = Object.entries(attrs)
    token.meta = { coplanImage: attrs }
    token.children = []; token.content = attrs.alt
  }
  state.pos += match[0].length
  return true
})
// Run before links, but after escapes and code spans. A citation is inline
// content, so it must not turn its entire paragraph or list into a source card.
// The rich parser disables HTML. Use HTML-aware block boundaries to recognize
// standalone comments even when they interrupt an ordinary paragraph.
const htmlBlockTokenizer = new tokenizer.constructor("commonmark", { html: true })
tokenizer.inline.ruler.before("link", "coplan_footnote", (state, silent) => {
  const match = /^\[\^([^\]]+)\]/.exec(state.src.slice(state.pos))
  if (!match || !citationLabelKey(match[1])) return false
  if (!silent) state.push("footnote_reference", "", 0).meta = { label: match[1] }
  state.pos += match[0].length
  return true
})
// Keep a table's own node inside its surrounding list or blockquote. The
// list remains rich text; only the table uses a source-preserving preview.
tokenizer.enable(["table", "strikethrough"])
// Task markers belong to their list item, not the editable paragraph text.
// Remove them before inline parsing so marks, links and nested lists stay rich.
tokenizer.core.ruler.after("block", "coplan_tasks", state => {
  state.tokens.forEach((token, index) => {
    if (token.type !== "list_item_open" || state.tokens[index + 1]?.type !== "paragraph_open") return
    const inline = state.tokens[index + 2]
    const match = inline?.type === "inline" && /^\[([ xX])\](?:[ \t]+|$)/.exec(inline.content)
    if (!match) return
    token.meta = { checked: match[1] !== " " }
    inline.content = inline.content.slice(match[0].length)
  })
})
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
  s: { mark: "strikethrough" },
  list_item: { block: "list_item", getAttrs: token => ({ checked: token.meta?.checked ?? null }) },
  image: { node: "image", getAttrs: token => ({ ...(token.meta?.coplanImage || defaultMarkdownParser.tokens.image.getAttrs(token)), width: imageWidth(token.attrGet("width")) }) },
  footnote_reference: { node: "footnote_reference", getAttrs: token => token.meta },
  preserved_block: { node: "preserved", getAttrs: token => token.meta }
})
const defaultMarkdownSerializer = new MarkdownSerializer({
  ...baseMarkdownSerializer.nodes,
  list_item: (state, node) => {
    if (node.attrs.checked !== null) state.write(`[${node.attrs.checked ? "x" : " "}] `)
    state.renderContent(node)
  },
  image: (state, node) => {
    if (!node.attrs.width) return baseMarkdownSerializer.nodes.image(state, node)
    const image = document.createElement("img")
    for (const name of ["src", "alt", "title", "width"]) if (node.attrs[name] != null) image.setAttribute(name, node.attrs[name])
    state.text(image.outerHTML, false)
  },
  footnote_reference: (state, node) => state.text(`[^${node.attrs.label}]`, false),
  template_note: (state, node) => {
    state.write(node.attrs.opening + node.textContent + node.attrs.closing.trimEnd())
    state.closeBlock(node)
  },
  preserved: (state, node) => {
    for (const line of node.attrs.source.trimEnd().split("\n")) { state.write(line); state.ensureNewLine() }
    state.closeBlock(node)
  }
}, { ...baseMarkdownSerializer.marks, strikethrough: { open: "~~", close: "~~", mixable: true, expelEnclosingWhitespace: true } })

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
  // Standalone HTML comments are editable guidance, hidden in reading view.
  // Scan complete comments so blank lines and Markdown-looking note text stay
  // together. Code, lists, quotes and presentation wrappers keep their source.
  const noteStarts = new Set(definitionsOnly ? [] : htmlBlockTokenizer.parse(markdown, {})
    .filter(token => token.type === "html_block" && token.level === 0 && /^ {0,3}<!--/.test(token.content))
    .map(token => token.map[0]))
  if (!definitionsOnly) for (let line = 0; line < lines.length; line++) {
    if (!noteStarts.has(line) || !/^ {0,3}<!--/.test(lines[line]) ||
      specials.some(range => offsets[line] >= range.from && offsets[line] < range.to)) continue
    const end = markdown.indexOf("-->", offsets[line] + lines[line].indexOf("<!--") + 4)
    if (end < 0) continue
    const endLine = lines.findIndex((_, index) => offsets[index] <= end && offsets[index + 1] > end)
    if (!/^[ \t]*\r?$/.test(markdown.slice(end + 3, Math.min(offsets[endLine + 1] - 1, markdown.length)))) continue
    specials.push({ from: offsets[line], to: Math.min(offsets[endLine + 1], markdown.length), kind: "template_note" })
    line = endLine
  }
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
  return last?.type === schema.nodes.code_block || last?.type === schema.nodes.preserved || last?.type === schema.nodes.template_note
}
function ensureTrailing(doc) {
  return needsTrailing(doc) ? doc.copy(doc.content.append(Fragment.from(trailingParagraph()))) : doc
}
function moveBelowCode(state, dispatch, view) {
  // A native ArrowLeft can move the caret before selectionchange updates
  // the model. Do not escape code using its previous end-of-block position.
  const { $from, $to: $head } = visibleSelection(state, view)
  if ($from.pos === $head.pos && $head.parent.type === schema.nodes.code_block && dispatch) {
    const selection = TextSelection.create(state.doc, $head.pos)
    if (!selection.eq(state.selection)) dispatch(state.tr.setSelection(selection))
  }
  if ($from.pos !== $head.pos || $head.parent.type !== schema.nodes.code_block || $head.parentOffset !== $head.parent.content.size) return false
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
function liftEmptyListItem(state, dispatch) {
  const { empty, $from } = state.selection
  if (!empty || $from.parent.type !== schema.nodes.paragraph || $from.parent.content.size ||
      $from.depth < 2 || $from.node(-1).type !== schema.nodes.list_item || $from.node(-1).childCount !== 1) return false
  return liftListItem(schema.nodes.list_item)(state, dispatch)
}
function splitRichListItem(state, dispatch) {
  const { $from } = state.selection
  const task = $from.depth >= 2 && $from.node(-1).type === schema.nodes.list_item && $from.node(-1).attrs.checked !== null
  return splitListItem(schema.nodes.list_item, task ? { checked: false } : null)(state, dispatch && (tr => {
    // The base command inherits item attrs when splitting mid-paragraph.
    // A newly continued task always starts unchecked, wherever it was split.
    const { $from: next } = tr.selection
    if (task && next.depth >= 2 && next.node(-1).type === schema.nodes.list_item) {
      const item = next.node(-1)
      tr.setNodeMarkup(next.before(-1), null, { ...item.attrs, checked: false })
    }
    dispatch(tr)
  }))
}
function joinParagraphToPreviousList(state, dispatch) {
  const { empty, $from } = state.selection
  if (!empty || $from.parent.type !== schema.nodes.paragraph || $from.parent.content.size || $from.parentOffset) return false
  const previous = state.doc.resolve($from.before()).nodeBefore
  if (![schema.nodes.bullet_list, schema.nodes.ordered_list].includes(previous?.type)) return false
  // A textblock join cannot cross a preserved table at the end of a list.
  // Remove only the empty paragraph, then skip atoms to the preceding text.
  const position = $from.before()
  const tr = state.tr.delete(position, $from.after())
  const selection = TextSelection.findFrom(tr.doc.resolve(position), -1, true)
  if (!selection) return false
  if (dispatch) dispatch(tr.setSelection(selection).scrollIntoView())
  return true
}
function preserved(source, kind = null, label = null) {
  if (!kind && source.trimStart().startsWith("[")) {
    const environment = {}
    if (!tokenizer.parse(source, environment).length && Object.keys(environment.references || {}).length) kind = "link_reference"
  }
  return schema.nodes.preserved.create({ source, kind, label })
}
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
    if (segment.kind === "template_note") {
      const [, opening, body, closing] = /^(\s*<!--\s*)([\s\S]*?)(\s*-->[ \t]*(?:\r?\n)?)$/.exec(segment.source)
      const node = schema.nodes.template_note.create({ opening, closing }, body ? schema.text(body) : null)
      if (templateNoteClosesEarly(node)) { blocks.push(preserved(segment.source)); continue }
      blocks.push(node.type.create({ ...node.attrs, source: segment.source, snapshot: signature(node) }, node.content))
      continue
    }
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
        const unsupported = text.replace(imageTag, tag => htmlImage(tag) ? "" : tag)
        if (parsed.firstChild?.type.name !== "code_block" && /\]\s*\[|<\/?[a-z!]|^\s*\[[^\]]+\]:|^:::(?: \{\.presentation.*\})?$/im.test(unsupported)) throw new Error("preserve")
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
    const unchanged = node.type.name === "preserved" ? !node.attrs.inserted : (node.attrs.source !== null && node.attrs.snapshot === signature(node))
    const source = unchanged ? node.attrs.source : node.type.name === "template_note" ?
      node.attrs.opening + node.textContent + node.attrs.closing : defaultMarkdownSerializer.serialize(schema.topNodeType.create(null, node))
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
  if (node.type === schema.nodes.template_note)
    return range.from + node.attrs.opening.length + Math.max(0, Math.min(node.content.size, position - blockPosition - 1))
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
  if (node.type === schema.nodes.template_note)
    return block.position + 1 + Math.max(0, Math.min(node.content.size, offset - block.range.from - node.attrs.opening.length))
  const { positions, sourcePositions } = blockSourceMap(node, block.position, source.slice(block.range.from, block.range.to))
  if (!positions.length) return Math.min(doc.content.size, block.position + node.nodeSize)
  const within = Math.max(0, offset - block.range.from)
  const next = sourcePositions.findIndex(sourcePosition => sourcePosition !== null && sourcePosition >= within)
  return next < 0 ? positions.at(-1) + 1 : positions[next]
}

function templateNoteClosesEarly(node) {
  return /--!?>/.test(node.textContent) ||
    (node.attrs.opening.endsWith("<!--") && /^(?:>|->)/.test(node.textContent))
}
function hasInvalidTemplateNote(doc) {
  let invalid = false
  doc.descendants(node => {
    if (node.type !== schema.nodes.template_note) return
    invalid ||= templateNoteClosesEarly(node)
    return false
  })
  return invalid
}
function rangeTouchesTemplateNote(doc, from, to) {
  let touches = false
  doc.nodesBetween(from, to, node => {
    if (node.type === schema.nodes.template_note) touches = true
    return !touches
  })
  return touches
}
function selectionTouchesTemplateNote(state) {
  return rangeTouchesTemplateNote(state.doc, state.selection.from, state.selection.to)
}
function proseCommand(command) {
  return (state, dispatch, view) => selectionTouchesTemplateNote(state) || command(state, dispatch, view)
}
function preventTemplateNoteJoin(view, event, backward) {
  if (!event.cancelable || !event.target?.isContentEditable) return false
  // Native deletion can precede selectionchange. Keep the browser from
  // joining hidden guidance to adjacent document text using a stale caret.
  const { $from, $to } = visibleSelection(view.state, view)
  if ($from.pos !== $to.pos || $from.parent.type !== schema.nodes.template_note ||
      $from.parentOffset !== (backward ? 0 : $from.parent.content.size)) return false
  event.preventDefault()
  if (!$from.parent.content.size) {
    const position = $from.before()
    const tr = view.state.tr.delete(position, $from.after())
    const $position = tr.doc.resolve(position)
    const direction = backward ? -1 : 1
    const selection = TextSelection.findFrom($position, direction, true) || TextSelection.findFrom($position, -direction, true)
    if (selection) tr.setSelection(selection)
    view.dispatch(closeHistory(tr).scrollIntoView())
  }
  return true
}

function taskItemNodeView(node) {
  if (node.attrs.checked === null) return null
  const { dom, contentDOM } = DOMSerializer.renderSpec(document, node.type.spec.toDOM(node))
  const checkbox = dom.querySelector("input")
  return { dom, contentDOM, update(next) {
    if (next.type !== node.type || next.attrs.checked === null) return false
    // Keep the checkbox DOM stable for keyboard focus while text or state changes.
    checkbox.checked = next.attrs.checked
    checkbox.setAttribute("aria-label", `Task: ${next.firstChild.textContent}`)
    dom.dataset.coplanTask = String(next.attrs.checked)
    node = next
    return true
  } }
}

function hiddenCommentBlocks(state) {
  const blocks = []
  let supported = true
  state.doc.nodesBetween(state.selection.from, state.selection.to, (node, position, parent) => {
    if (parent !== state.doc) return false
    if (node.type === schema.nodes.preserved && !node.attrs.source.trim()) return false
    if (!["paragraph", "heading", "code_block", "template_note"].includes(node.type.name)) { supported = false; return false }
    node.forEach(child => { if (!child.isText && child.type.name !== "hard_break") supported = false })
    blocks.push({ node, position })
    return false
  })
  return supported ? blocks : []
}
function setTextStyle(type, attrs = null) {
  return (state, dispatch) => {
    const { from, to } = state.selection
    const notes = []
    state.doc.nodesBetween(from, to, (node, position) => {
      if (node.type === schema.nodes.template_note) { notes.push({ node, position }); return false }
    })
    if (!notes.length) return setBlockType(type, attrs)(state, dispatch)
    if (dispatch) {
      const tr = state.tr
      for (const { node, position } of notes.toReversed()) {
        const lines = node.textContent.split("\n")
        if (type === schema.nodes.heading) {
          // Markdown headings end at the source newline. Each line needs its
          // own block so saving and reopening preserves the chosen style.
          tr.replaceWith(position, position + node.nodeSize, lines.map(line => type.create(attrs, line ? schema.text(line) : null)))
        } else {
          const content = []
          lines.forEach((line, index) => {
            if (index) content.push(type === schema.nodes.code_block ? schema.text("\n") : schema.nodes.hard_break.create())
            if (line) content.push(schema.text(line))
          })
          tr.replaceWith(position, position + node.nodeSize, type.create(attrs, content))
        }
      }
      const mapPosition = position => {
        const note = notes.find(entry => position > entry.position && position < entry.position + entry.node.nodeSize)
        if (!note) return tr.mapping.map(position)
        const offset = position - note.position - 1
        const extra = type === schema.nodes.heading ? note.node.textContent.slice(0, offset).split("\n").length - 1 : 0
        return tr.mapping.map(note.position, -1) + 1 + offset + extra
      }
      const mappedFrom = mapPosition(from), mappedTo = mapPosition(to)
      tr.setSelection(TextSelection.between(tr.doc.resolve(mappedFrom), tr.doc.resolve(mappedTo)))
      tr.setBlockType(mappedFrom, mappedTo, type, attrs)
      dispatch(closeHistory(tr))
    }
    return true
  }
}
function setHiddenComment(state, dispatch) {
  const blocks = hiddenCommentBlocks(state)
  if (!blocks.length) return false
  if (dispatch) {
    const tr = state.tr
    for (const { node, position } of blocks.toReversed()) {
      if (node.type === schema.nodes.template_note) continue
      const text = node.textBetween(0, node.content.size, "", "\n")
      tr.replaceWith(position, position + node.nodeSize, schema.nodes.template_note.create(
        { opening: "<!-- ", closing: " -->" }, text ? schema.text(text) : null))
    }
    tr.setSelection(TextSelection.between(tr.doc.resolve(state.selection.from), tr.doc.resolve(state.selection.to)))
    dispatch(closeHistory(tr))
  }
  return true
}

export function createRichDocument(element, markdown, changed, selectionChanged = () => {}, preview = null, comments = []) {
  let rangeDoc, ranges, previewOffsetTimer, editingLanguage = false
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
    plugins: [history(), inputRules({ rules: [wrappingInputRule(/^\* $/, schema.nodes.bullet_list)] }),
      codeHighlight(), commentPlugin(comments), new Plugin({ appendTransaction(transactions, oldState, state) {
      if (transactions.some(tr => tr.docChanged) && needsTrailing(state.doc))
        return state.tr.insert(state.doc.content.size, trailingParagraph()).setMeta("addToHistory", false)
    } }), keymap({
      "Mod-a": selectFocusedText, ...lineNavigation,
      "Mod-b": proseCommand(toggleMark(schema.marks.strong)), "Mod-i": proseCommand(toggleMark(schema.marks.em)),
      "Mod-z": undo, "Mod-Shift-z": redo, "Mod-y": redo,
      "Ctrl-b": proseCommand(toggleMark(schema.marks.strong)), "Meta-b": proseCommand(toggleMark(schema.marks.strong)),
      "Ctrl-i": proseCommand(toggleMark(schema.marks.em)), "Meta-i": proseCommand(toggleMark(schema.marks.em)),
      "Ctrl-z": undo, "Meta-z": undo, "Ctrl-Shift-z": redo, "Meta-Shift-z": redo, "Ctrl-y": redo,
      "Shift-Enter": chainCommands(codeNewline, (state, dispatch) => { if (dispatch) dispatch(state.tr.replaceSelectionWith(schema.nodes.hard_break.create()).scrollIntoView()); return true }),
      "Mod-Enter": exitCode, ArrowDown: moveBelowCode,
      "Mod-k": proseCommand(linkCommand), "Ctrl-k": proseCommand(linkCommand), "Meta-k": proseCommand(linkCommand),
      "Mod-Shift-7": proseCommand(wrapInList(schema.nodes.ordered_list)), "Mod-Shift-8": proseCommand(wrapInList(schema.nodes.bullet_list)),
      "Mod-Alt-0": proseCommand(setBlockType(schema.nodes.paragraph)), "Mod-Alt-1": proseCommand(setBlockType(schema.nodes.heading, { level: 1 })),
      "Mod-Alt-2": proseCommand(setBlockType(schema.nodes.heading, { level: 2 })), "Mod-Alt-3": proseCommand(setBlockType(schema.nodes.heading, { level: 3 })),
      Enter: (state, dispatch, view) => {
        if (dispatch && view) state = synchronizeSelection(view)
        return chainCommands(codeNewline, splitRichListItem)(state, dispatch, view)
      }, Tab: chainCommands(indentCode, sinkListItem(schema.nodes.list_item)),
      Backspace: chainCommands(undoInputRule, liftEmptyListItem, joinParagraphToPreviousList),
      "Shift-Tab": liftListItem(schema.nodes.list_item)
    }), keymap(baseKeymap)]
  })
  const view = new EditorView(element, {
    state, nodeViews: {
      list_item: taskItemNodeView,
      preserved: (node, view, getPos) => sourceNodeView(node, view, getPos, preview, sourceRangeAt),
      image: (node, view, getPos) => imageNodeView(node, view, getPos),
      code_block: (node, view, getPos) => codeNodeView(node, view, getPos, preview, sourceRangeAt)
    }, attributes: { class: "markdown-rendered", role: "textbox", "aria-label": "Document body", "aria-multiline": "true" },
    handleDOMEvents: {
      mouseup(view) {
        synchronizeSelection(view)
        return false
      },
      change(view, event) {
        if (!event.target.matches("input[data-coplan-task-checkbox]")) return false
        const position = view.posAtDOM(event.target.closest("li"), 0) - 1
        const node = view.state.doc.nodeAt(position)
        if (node?.type !== schema.nodes.list_item || node.attrs.checked === null) return false
        view.dispatch(closeHistory(view.state.tr.setNodeMarkup(position, null, { ...node.attrs, checked: event.target.checked })))
        return true
      },
      keydown(view, event) {
        return ["Backspace", "Delete"].includes(event.key) && preventTemplateNoteJoin(view, event, event.key === "Backspace")
      },
      beforeinput(view, event) {
        return /^delete.*(?:Backward|Forward)$/.test(event.inputType) && preventTemplateNoteJoin(view, event, event.inputType.endsWith("Backward"))
      },
      copy(view, event) {
        const slice = view.state.selection.content()
        let hasSourceBlock = false
        slice.content.forEach(node => { if (["preserved", "code_block", "template_note"].includes(node.type.name)) hasSourceBlock = true })
        if (!hasSourceBlock || slice.openStart || slice.openEnd || !event.clipboardData) return false
        const source = serializeDocument(schema.topNodeType.create(null, slice.content))
        event.clipboardData.setData("text/plain", source)
        event.clipboardData.setData("application/x-coplan-markdown", source)
        event.preventDefault()
        return true
      }
    },
    handlePaste(view, event) {
      if (view.state.selection.$from.parent.type.spec.code) return false
      const source = event.clipboardData?.getData("application/x-coplan-markdown") || event.clipboardData?.getData("text/plain")
      if (!source || !/(^|\n)```[^\n]*\n|^\s*\|[^\n]+\|\s*\n\s*\|?\s*:?-{3,}|^ {0,3}<!--[\s\S]*?-->/m.test(source)) return false
      const parsed = parseDocument(source)
      // These blocks have no existing boundary in the destination document.
      // Treat them as inserted so lossless source attrs cannot join them to
      // unchanged prose when either side has no trailing newline.
      const inserted = []
      parsed.forEach(node => inserted.push(node.type.create({ ...node.attrs,
        ...(node.type === schema.nodes.preserved ? { inserted: true } : { source: null, snapshot: null })
      }, node.content, node.marks)))
      view.dispatch(view.state.tr.replaceSelection(new Slice(Fragment.fromArray(inserted), 0, 0)).scrollIntoView())
      return true
    },
    dispatchTransaction(transaction) {
      // Check every rich transaction, including paste, composition and undo.
      // A note must never serialize text outside its HTML comment wrapper.
      if (transaction.docChanged && hasInvalidTemplateNote(transaction.doc)) {
        view.updateState(view.state)
        selectionChanged(toolbarState(view.state))
        element.dispatchEvent(new CustomEvent("coplan:template-note-rejected", { bubbles: true }))
        return
      }
      if (transaction.docChanged) {
        // Keep successive keystrokes together, but fence transitions between
        // language and content even inside history's grouping delay.
        const languageEdit = Boolean(transaction.getMeta("coplan-language-edit"))
        if (languageEdit !== editingLanguage) closeHistory(transaction)
        editingLanguage = languageEdit
      }
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
        for (const block of view.dom.querySelectorAll(".document-editor__content-block")) block.coplanRefreshPreview?.()
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
    closeHistory() { view.dispatch(closeHistory(view.state.tr)) },
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
    updateComments(next, { preserveRanges = false } = {}) {
      view.dispatch(view.state.tr.setMeta(commentKey, { comments: next, preserveRanges }).setMeta("addToHistory", false))
    },
    focusText(text, occurrence = 0) {
      const wanted = text?.replace(/\s+/g, " ").trim()
      let match = 0, position = null
      if (wanted) view.state.doc.descendants((node, pos) => {
        if ([schema.nodes.code_block, schema.nodes.template_note].includes(node.type)) return false
        if (!node.isTextblock) return
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
      synchronizeSelection(view)
    },
    insertCode(language = "") {
      if (selectionTouchesTemplateNote(view.state)) return false
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
      view.dispatch(view.state.tr.setNodeMarkup(position, null, { ...node.attrs, params: language }).setMeta("coplan-language-edit", true))
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
      if (selectionTouchesTemplateNote(view.state) && !["undo", "redo", "paragraph", "heading", "code_block", "hidden_comment"].includes(name)) { view.focus(); return false }
      const commands = {
        bold: toggleMark(schema.marks.strong), italic: toggleMark(schema.marks.em),
        heading: setTextStyle(schema.nodes.heading, { level: Number(value || 2) }), paragraph: setTextStyle(schema.nodes.paragraph), code_block: setTextStyle(schema.nodes.code_block),
        hidden_comment: setHiddenComment,
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
        if (incoming) {
          const known = new Set(comments.map(comment => comment.id))
          comments = incoming.comments
          if (!incoming.preserveRanges) return commentDecorations(state.doc, comments)
          // A saved-thread refresh may describe the last acknowledged text
          // while a newer local edit has already mapped its highlight. Keep
          // those provisional ranges until that edit is acknowledged. Status
          // changes and deleted threads still apply immediately.
          const byId = new Map(comments.map(comment => [comment.id, comment]))
          const kept = previous.find().flatMap(mark => {
            const comment = byId.get(mark.type.attrs["data-thread-id"])
            if (!comment || rangeTouchesTemplateNote(state.doc, mark.from, mark.to) || state.doc.textBetween(mark.from, mark.to) !== mark.spec.expected) return []
            return [Decoration.inline(mark.from, mark.to, {
              ...mark.type.attrs, class: `anchor-highlight anchor-highlight--${comment.status}`
            }, mark.spec)]
          })
          // A quote invalidated by a broad local rewrite must stay detached;
          // looking up its old text could attach it to another occurrence.
          const added = commentDecorations(state.doc, comments.filter(comment => !known.has(comment.id))).find()
          return DecorationSet.create(state.doc, [...kept, ...added])
        }
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
          if (rangeTouchesTemplateNote(state.doc, mark.from, mark.to)) return []
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
    if (node.type === schema.nodes.template_note) return false
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
    heading: ancestor("template_note") ? "comment" : ancestor("code_block") ? "code" : ancestor("heading")?.attrs.level || 0,
    canHideComment: hiddenCommentBlocks(state).length > 0,
    templateNote: selectionTouchesTemplateNote(state), undo: undo(state), redo: redo(state) }
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

// Code boxes and template notes are their own text selection scope.
// ProseMirror's selectAll includes every other code/prose block.
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
function synchronizeSelection(view) {
  const { $from, $to } = visibleSelection(view.state, view)
  if ($from.parent.inlineContent && $to.parent.inlineContent) {
    const selection = TextSelection.create(view.state.doc, $from.pos, $to.pos)
    if (!selection.eq(view.state.selection)) view.dispatch(view.state.tr.setSelection(selection))
  }
  return view.state
}
function selectFocusedText(state, dispatch, view) {
  const { $from, $to } = visibleSelection(state, view)
  if ($from.sameParent($to) && [schema.nodes.code_block, schema.nodes.template_note].includes($from.parent.type)) {
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

// ProseMirror owns image identity/history; Stimulus owns the resize gesture.
// Preview dimensions never enter the document until the gesture is committed.
function imageNodeView(initial, view, getPos) {
  let node = initial
  const dom = document.createElement("span")
  dom.className = "document-editor__image"
  dom.contentEditable = "false"
  dom.dataset.controller = "coplan--image-resize"
  dom.dataset.action = "coplan:image-updated->coplan--image-resize#cancel blur@window->coplan--image-resize#cancel"
  const image = document.createElement("img")
  image.setAttribute("data-coplan--image-resize-target", "image")
  image.draggable = false
  const handle = document.createElement("button")
  handle.type = "button"; handle.className = "document-editor__image-handle"
  handle.setAttribute("aria-label", "Resize image")
  handle.title = "Drag to resize · drag to full width to reset. Arrow keys resize; End resets."
  handle.setAttribute("data-coplan--image-resize-target", "handle")
  handle.dataset.action = "click->coplan--image-resize#focus:prevent:stop pointerdown->coplan--image-resize#start pointermove->coplan--image-resize#move pointerup->coplan--image-resize#finish pointercancel->coplan--image-resize#cancel lostpointercapture->coplan--image-resize#cancel keydown->coplan--image-resize#keydown"
  const corner = document.createElementNS("http://www.w3.org/2000/svg", "svg")
  corner.setAttribute("viewBox", "0 0 24 24"); corner.setAttribute("aria-hidden", "true")
  const grip = document.createElementNS("http://www.w3.org/2000/svg", "path")
  grip.setAttribute("d", "M8 19 19 8 M13 19 19 13 M18 19 19 18")
  corner.append(grip); handle.append(corner)
  const status = document.createElement("output")
  status.className = "document-editor__image-size"
  status.setAttribute("data-coplan--image-resize-target", "status")
  status.setAttribute("aria-live", "polite")
  dom.append(image, handle, status)
  const render = () => {
    for (const name of ["src", "alt", "title", "width"]) {
      if (node.attrs[name] == null) image.removeAttribute(name)
      else image.setAttribute(name, node.attrs[name])
    }
  }
  dom.coplanCommitWidth = width => {
    const position = getPos()
    if (position == null || view.state.doc.nodeAt(position) !== node || width === node.attrs.width) return
    const tr = closeHistory(view.state.tr.setNodeMarkup(position, null, { ...node.attrs, width }))
    view.dispatch(tr)
    // Do not merge later typing or a second gesture into this undo step.
    view.dispatch(closeHistory(view.state.tr))
  }
  render()
  return { dom, update(next) {
    if (next.type !== node.type) return false
    dom.dispatchEvent(new CustomEvent("coplan:image-updated"))
    node = next; render(); return true
  }, stopEvent: event => !(event.type === "keydown" && (event.metaKey || event.ctrlKey) && ["z", "y"].includes(event.key.toLowerCase())), ignoreMutation: () => true,
  destroy() { dom.dispatchEvent(new CustomEvent("coplan:image-updated")); delete dom.coplanCommitWidth } }
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
  if (["reference", "link_reference"].includes(node.attrs.kind)) {
    dom.hidden = true
    return { dom, update: next => next.type === node.type && next.attrs.kind === node.attrs.kind,
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
      toggle.className = "document-editor__presentation-preview"
      toggle.dataset.action = "coplan--editor#togglePresentationPreview"
      toggle.setAttribute("aria-expanded", "false")
      dom.querySelector(".document-editor__block-header").insertBefore(toggle, copy)
      const body = document.createElement("div"); body.className = "document-editor__block-preview"; body.hidden = true
      const status = document.createElement("small"); status.setAttribute("role", "status"); status.hidden = true; title.after(status)
      const input = document.createElement("textarea")
      input.className = "document-editor__block-source"
      input.setAttribute("aria-label", "Presentation Markdown")
      input.dataset.action = "input->coplan--editor#blockSourceChanged keydown->coplan--editor#blockKeydown"
      input.value = presentationContent(node.attrs.source).content
      dom.append(input, body)
      let renderedSource = null, renderedDeck = null, previewTimer
      const previewSource = () => serializeDocument(view.state.doc)
      const renderPreview = async () => {
        const sequence = ++generation
        const source = previewSource()
        let deckIndex = 0, before = true
        view.state.doc.descendants((item, position) => {
          if (position === getPos()) before = false
          if (before && item.attrs.kind === "presentation") deckIndex++
        })
        renderedSource = source
        if (!renderedDeck) body.textContent = "Loading preview…"
        status.hidden = true
        if (renderedDeck) toggle.textContent = "Refreshing…"
        body.setAttribute("aria-busy", "true")
        try {
          const html = await preview(source)
          if (sequence === generation) {
            const template = document.createElement("template"); template.innerHTML = html
            const deck = template.content.querySelectorAll(".deck-region")[deckIndex]
            if (!deck) throw new Error("Presentation unavailable")
            if (renderedDeck !== deck.outerHTML) {
              renderedDeck = deck.outerHTML
              body.replaceChildren(deck)
            }
            status.textContent = ""
          }
        } catch {
          if (sequence === generation) {
            if (renderedDeck) { status.textContent = "Could not refresh preview. Toggle Preview to retry."; status.hidden = false }
            else body.textContent = "Preview unavailable. Return to Markdown to keep editing."
          }
        } finally {
          if (sequence === generation) {
            body.removeAttribute("aria-busy")
            if (!body.hidden) toggle.textContent = "Edit Markdown"
          }
        }
      }
      // Definition nodes can change without updating the presentation node.
      // Check dependencies after the complete document transaction is applied.
      dom.coplanRefreshPreview = () => {
        if (!body.hidden && renderedSource !== previewSource()) {
          generation++; clearTimeout(previewTimer)
          previewTimer = setTimeout(() => { if (!body.hidden) renderPreview() }, 300)
        }
      }
      dom.coplanTogglePreview = () => {
        const showing = body.hidden
        toggle.setAttribute("aria-expanded", String(showing))
        toggle.textContent = showing ? "Edit Markdown" : "Preview"
        input.hidden = showing; body.hidden = !showing
        clearTimeout(previewTimer)
        if (showing) return renderPreview()
        generation++; body.removeAttribute("aria-busy"); status.hidden = true
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
        if (changed && !body.hidden) generation++
        return true
      }, stopEvent: () => true, ignoreMutation: () => true, destroy() { generation++; clearTimeout(previewTimer) } }
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
    const settlePreview = (content, asText = false) => {
      // A preview above the active field/button must not move it mid-action.
      // Pointer-down can precede the browser moving focus to its button.
      // Citation controls share the plan's editor but sit outside ProseMirror.
      const interactionRoot = view.dom.closest('[data-controller~="coplan--inline-editor"]') || form || view.dom
      const pressed = interactionRoot.querySelector("input:active, textarea:active, button:active, select:active")
      const focused = pressed || document.activeElement
      const control = interactionRoot.contains(focused) && focused.matches("input, textarea, button, select") && !previewBody.contains(focused) ? focused : null
      const bounds = control?.getBoundingClientRect()
      // Focus can remain in a field after someone scrolls away to read.
      // That offscreen field must not pull the page when a preview finishes.
      const visible = bounds && bounds.bottom > 0 && bounds.top < window.innerHeight
      if (asText) previewBody.textContent = content
      else previewBody.innerHTML = content
      if (control?.isConnected && visible) window.scrollBy(0, control.getBoundingClientRect().top - bounds.top)
    }
    let previewTimer
    const render = () => {
      clearTimeout(previewTimer)
      const sequence = ++generation, source = node.attrs.source
      previewTimer = setTimeout(async () => {
        try { const html = await preview?.(source); if (html && sequence === generation) settlePreview(html) }
        catch { if (sequence === generation) settlePreview("Preview unavailable", true) }
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
  language.dataset.action = "focus->coplan--editor#languageEditingBoundary input->coplan--editor#languageInput change->coplan--editor#languageChanged blur->coplan--editor#languageEditingBoundary"
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
