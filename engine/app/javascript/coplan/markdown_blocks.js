// A `markdown` or `md` fence in the reading view renders as a Markdown
// block: a rendered pane plus the literal source <pre>, one of them hidden
// (see MarkdownHelper#render_markdown_blocks). The source stays the anchor
// text model in either view, so comments are stored against source text.
// This module maps positions between the two views so a selection in the
// rendered pane can become a source selection, and a highlight in the
// source can be drawn over the rendered text when that view is showing.
//
// Positions are character offsets into the block's body: the text of the
// source <code>. The server stamps rendered elements with the body range
// they came from (data-markdown-from/to). Inside one element, each text
// node is found in that range from a running cursor, so the text of a link
// maps to its label and not its URL. Characters with no source counterpart,
// such as footnote numbers, stay unmapped.

export const BLOCK_SELECTOR = "[data-markdown-block]"
export const RENDERED_SELECTOR = "[data-markdown-block-rendered]"
export const CHROME_SELECTOR = "[data-markdown-block-chrome]"
const SOURCE_SELECTOR = ":scope > pre[data-markdown-block-source] > code"
// Text in the rendered pane that never maps to source.
const UNMAPPED_SELECTOR = "style, script, noscript, svg, button, [data-math-style], .footnotes-title, .footnote-backref, .footnote-ref, [data-footnote-ref]"
// How far past the cursor a single unmatched character may be found.
// Covers escapes and entities without letting stray letters jump ahead.
const CHARACTER_WINDOW = 8

const elementOf = node => node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement

export function renderedBlockAt(node) {
  const pane = elementOf(node)?.closest(RENDERED_SELECTOR)
  return pane?.closest(BLOCK_SELECTOR) || null
}

// The block showing its rendered pane whose hidden source holds `node`.
export function renderedBlockForSource(node) {
  const code = elementOf(node)?.closest("pre[data-markdown-block-source] > code")
  const block = code?.parentElement.closest(BLOCK_SELECTOR)
  return block && !rendered(block).hidden ? block : null
}

function rendered(block) {
  return block.querySelector(`:scope > ${RENDERED_SELECTOR}`)
}

function sourceNodes(block) {
  const code = block.querySelector(SOURCE_SELECTOR)
  const nodes = []
  if (!code) return nodes
  const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT)
  let start = 0
  let node
  while ((node = walker.nextNode())) {
    nodes.push({ node, start })
    start += node.textContent.length
  }
  return nodes
}

// Body offset of a position inside the source <code>.
export function sourceOffset(block, node, offset) {
  const entry = sourceNodes(block).find(candidate => candidate.node === node)
  return entry ? entry.start + offset : null
}

// The source text node and local offset for a body offset. An end
// boundary prefers the node the offset closes over the one it opens.
function sourcePoint(block, offset, { end = false } = {}) {
  const nodes = sourceNodes(block)
  for (const { node, start } of nodes) {
    const length = node.textContent.length
    if (offset < start + length || (end && offset === start + length)) return { node, offset: offset - start }
  }
  const last = nodes.at(-1)
  return last ? { node: last.node, offset: last.node.textContent.length } : null
}

// Every rendered text node with the body offset of each character, or
// null for a character with no source counterpart.
function renderedMap(block) {
  const pane = rendered(block)
  const source = sourceNodes(block).map(({ node }) => node.textContent).join("")
  const cursors = new Map()
  const stateFor = owner => {
    if (!cursors.has(owner)) {
      const from = Number.parseInt(owner.dataset.markdownFrom, 10)
      const to = Math.min(Number.parseInt(owner.dataset.markdownTo, 10), source.length)
      cursors.set(owner, { cursor: from, to })
    }
    return cursors.get(owner)
  }
  const entries = []
  const walker = document.createTreeWalker(pane, NodeFilter.SHOW_TEXT)
  let node
  while ((node = walker.nextNode())) {
    const text = node.textContent
    const owner = node.parentElement.closest("[data-markdown-from]")
    if (!text.trim() || node.parentElement.closest(UNMAPPED_SELECTOR) || !owner || !pane.contains(owner)) {
      entries.push({ node, offsets: new Array(text.length).fill(null) })
      continue
    }
    const state = stateFor(owner)
    entries.push({ node, offsets: align(text, source, state) })
    // Text after a formatted child is searched past it. In `**foo bar** bar`
    // the paragraph's " bar" must not match inside the bold phrase.
    for (let parent = owner.parentElement?.closest("[data-markdown-from]"); parent && pane.contains(parent);
      parent = parent.parentElement?.closest("[data-markdown-from]")) {
      const ancestor = stateFor(parent)
      ancestor.cursor = Math.max(ancestor.cursor, state.cursor)
    }
  }
  return entries
}

function align(text, source, state) {
  const offsets = new Array(text.length).fill(null)
  if (!Number.isFinite(state.cursor) || !Number.isFinite(state.to)) return offsets

  const found = source.indexOf(text, state.cursor)
  if (found >= 0 && found + text.length <= state.to) {
    for (let i = 0; i < text.length; i++) offsets[i] = found + i
    state.cursor = found + text.length
    return offsets
  }
  for (let i = 0; i < text.length; i++) {
    const whitespace = /\s/.test(text[i])
    const limit = Math.min(state.to, state.cursor + CHARACTER_WINDOW)
    for (let j = state.cursor; j < limit; j++) {
      if (whitespace ? /\s/.test(source[j]) : source[j] === text[i]) {
        offsets[i] = j
        state.cursor = j + 1
        break
      }
    }
  }
  return offsets
}

// Turns the parts of `range` that fall in a rendered pane into the matching
// source positions. Returns a new range, or null when a rendered end has
// nothing that maps to source (for example, only footnote numbers).
export function sourceRangeFor(range) {
  const startBlock = renderedBlockAt(range.startContainer)
  const endBlock = renderedBlockAt(range.endContainer)
  if (!startBlock && !endBlock) return range

  const mapped = range.cloneRange()
  if (startBlock) {
    const offset = boundaryOffset(startBlock, range, "start")
    const point = offset === null ? null : sourcePoint(startBlock, offset)
    if (!point) return null
    mapped.setStart(point.node, point.offset)
  }
  if (endBlock) {
    const offset = boundaryOffset(endBlock, range, "end")
    const point = offset === null ? null : sourcePoint(endBlock, offset, { end: true })
    if (!point) return null
    mapped.setEnd(point.node, point.offset)
  }
  return mapped.collapsed ? null : mapped
}

// The body offset of the first selected character (start), or just past
// the last selected character (end), among the block's rendered text.
function boundaryOffset(block, range, edge) {
  const entries = renderedMap(block).filter(({ node }) => range.intersectsNode(node))
  const ordered = edge === "start" ? entries : entries.reverse()
  for (const { node, offsets } of ordered) {
    let from = 0
    let to = offsets.length
    if (node === range.startContainer) from = range.startOffset
    if (node === range.endContainer) to = range.endOffset
    if (edge === "start") {
      for (let i = from; i < to; i++) if (offsets[i] !== null) return offsets[i]
    } else {
      for (let i = to - 1; i >= from; i--) if (offsets[i] !== null) return offsets[i] + 1
    }
  }
  return null
}

// Wraps the rendered text that came from body offsets [from, to) in marks.
// Marks never span text nodes, so the rendered structure stays intact.
export function markRendered(block, from, to, className) {
  const marks = []
  for (const { node, offsets } of renderedMap(block)) {
    let first = -1
    let last = -1
    offsets.forEach((offset, index) => {
      if (offset === null || offset < from || offset >= to) return
      if (first === -1) first = index
      last = index
    })
    if (first === -1) continue

    const range = document.createRange()
    range.setStart(node, first)
    range.setEnd(node, last + 1)
    const mark = document.createElement("mark")
    mark.className = className
    range.surroundContents(mark)
    marks.push(mark)
  }
  return marks
}
