// A `markdown` or `md` fence in the reading view renders as a Markdown
// block: a rendered pane plus the literal source <pre>, one of them hidden
// (see MarkdownHelper#render_markdown_blocks). The source stays the anchor
// text model in either view, so comments are stored against source text.
// This module maps positions between the two views so a selection in the
// rendered pane can become a source selection, and a highlight in the
// source can be drawn over the rendered text when that view is showing.
//
// Positions use UTF-16 offsets into the source <code>. The server supplies
// each element's source range and the shared parser's visible text/source
// spans. Matching within those ranges excludes URLs and markup, preserves
// whole entities and escapes, and advances across nested formatting.
// Generated text such as footnote numbers stays unmapped.

export const BLOCK_SELECTOR = "[data-markdown-block]"
export const RENDERED_SELECTOR = "[data-markdown-block-rendered]"
export const CHROME_SELECTOR = "[data-markdown-block-chrome]"
const SOURCE_SELECTOR = ":scope > pre[data-markdown-block-source] > code"
// Text in the rendered pane that never maps to source.
const UNMAPPED_SELECTOR = "style, script, noscript, svg, button, [data-math-style], .footnotes-title, .footnote-backref, .footnote-ref, [data-footnote-ref]"

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

// Every rendered text node with the source span of each UTF-16 unit, or
// null for a character with no source counterpart.
function renderedMap(block) {
  const pane = rendered(block)
  const mapping = JSON.parse(pane.dataset.markdownMap)
  // Index once by source start, then scan only the owner's interval.
  const indexed = mapping.spans.flatMap((span, index) => span && !/\s/u.test(mapping.text[index]) ? [{ span, character: mapping.text[index] }] : [])
    .sort((a, b) => a.span[0] - b.span[0])
  const cursors = new Map()
  const entries = []
  const walker = document.createTreeWalker(pane, NodeFilter.SHOW_TEXT)
  let node
  while ((node = walker.nextNode())) {
    const text = node.textContent
    const owner = node.parentElement.closest("[data-markdown-from]")
    const spans = new Array(text.length).fill(null)
    entries.push({ node, spans })
    if (!text.trim() || node.parentElement.closest(UNMAPPED_SELECTOR) || !owner || !pane.contains(owner)) continue

    const from = Math.max(Number(owner.dataset.markdownFrom || 0), cursors.get(owner) || 0)
    const to = Number(owner.dataset.markdownTo)
    // Search only parser-produced visible characters in this element's
    // source range. URLs, markup, and HTML attributes cannot be candidates.
    const candidates = [], characters = []
    let low = 0, high = indexed.length
    while (low < high) {
      const middle = (low + high) >>> 1
      if (indexed[middle].span[0] < from) low = middle + 1
      else high = middle
    }
    for (let index = low; index < indexed.length && indexed[index].span[0] < to; index++) {
      const { span, character } = indexed[index]
      if (span[1] > to) continue
      candidates.push(span)
      characters.push(character)
    }
    // The renderer adds layout newlines around nested lists and blocks.
    // Like writing provenance, align visible characters and let the mapped
    // endpoints retain the original source whitespace between them.
    const visible = [], offsets = []
    for (let i = 0; i < text.length; i++) {
      if (/\s/u.test(text[i])) continue
      visible.push(text[i]); offsets.push(i)
    }
    const found = characters.join("").indexOf(visible.join(""))
    if (found < 0) continue
    offsets.forEach((offset, index) => { spans[offset] = candidates[found + index] })

    // A parent's following text must start after its nested link/emphasis,
    // including when marks have split one text node into several nodes.
    const end = spans[offsets.at(-1)][1]
    for (let element = owner; element && pane.contains(element); element = element.parentElement) {
      cursors.set(element, Math.max(cursors.get(element) || 0, end))
    }
  }
  return entries
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
  for (const { node, spans } of ordered) {
    let from = 0
    let to = spans.length
    if (node === range.startContainer) from = range.startOffset
    if (node === range.endContainer) to = range.endOffset
    if (edge === "start") {
      for (let i = from; i < to; i++) if (spans[i] !== null) return spans[i][0]
    } else {
      for (let i = to - 1; i >= from; i--) if (spans[i] !== null) return spans[i][1]
    }
  }
  return null
}

// Wraps the rendered text that came from body offsets [from, to) in marks.
// Marks never span text nodes, so the rendered structure stays intact.
export function markRendered(block, from, to, className) {
  const marks = []
  for (const { node, spans } of renderedMap(block)) {
    let first = -1
    let last = -1
    spans.forEach((span, index) => {
      if (span === null || span[1] <= from || span[0] >= to) return
      if (first === -1) first = index
      last = index
    })
    if (first === -1) continue
    // Keep the visible gap between highlighted inline nodes. Layout-only
    // whitespace has no source span, but belongs to a range crossing it.
    while (first > 0 && /\s/u.test(node.textContent[first - 1]) && from < spans[first]?.[0]) first--
    while (last + 1 < spans.length && /\s/u.test(node.textContent[last + 1]) && to > spans[last]?.[1]) last++

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

// Structural table discussions use signed document ranges. Their rendered
// cell also carries the corresponding body range, so Source can show the
// same discussion without guessing which repeated cell text was selected.
export function markSource(block, from, to, className) {
  const marks = []
  for (const { node, start } of sourceNodes(block)) {
    const first = Math.max(0, from - start)
    const last = Math.min(node.textContent.length, to - start)
    if (last <= first) continue
    const range = document.createRange()
    range.setStart(node, first); range.setEnd(node, last)
    const mark = document.createElement("mark")
    mark.className = className
    range.surroundContents(mark)
    marks.push(mark)
  }
  return marks
}
