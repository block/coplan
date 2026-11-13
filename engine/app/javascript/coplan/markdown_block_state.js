import { textHunks } from "coplan/merge_text"

// Capture alongside deck positions, before the existing live-update swap.
// The document's surrounding text disambiguates identical drafts; mapping
// their positions through the shared text diff also survives body edits.
export function captureMarkdownBlockViews(root) {
  const blocks = Array.from(root.querySelectorAll("[data-markdown-block]"), element => ({
    source: element.querySelector(":scope > [data-markdown-block-source]"),
    view: element.querySelector(":scope > [data-markdown-block-source]").hidden ? "rendered" : "source",
    from: null, to: null
  }))
  if (!blocks.length) return { text: "", blocks }
  let text = "", node
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  while ((node = walker.nextNode())) {
    if (node.parentElement.closest("[data-markdown-block-rendered], [data-markdown-block-chrome]")) continue
    const block = blocks.find(candidate => candidate.source.contains(node))
    if (block) { block.from ??= text.length; block.to = text.length + node.textContent.length }
    text += node.textContent
  }
  return { text, blocks }
}

export function restoreMarkdownBlockViews(root, previous) {
  if (!previous.blocks.some(block => block.view === "source")) return
  const current = captureMarkdownBlockViews(root)
  const hunks = textHunks(previous.text, current.text)
  for (const block of previous.blocks) {
    if (block.view !== "source" || block.from === null) continue
    let position = block.from, delta = 0
    for (const hunk of hunks) {
      if (hunk.from > block.from) break
      if (hunk.to <= block.from) delta += hunk.text.length - (hunk.to - hunk.from)
      else { position = hunk.from; break }
    }
    position += delta
    const identical = current.blocks.filter(candidate => candidate.source.textContent === block.source.textContent)
    const match = identical.length === 1 ? identical[0] : current.blocks.find(candidate => candidate.from !== null && candidate.from <= position && position < candidate.to)
    if (!match) continue
    const element = match.source.parentElement
    match.source.hidden = false
    element.querySelector(":scope > [data-markdown-block-rendered]").hidden = true
    element.querySelectorAll("[data-view]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.view === "source")))
  }
}
