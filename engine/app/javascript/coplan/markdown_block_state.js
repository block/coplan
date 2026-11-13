import { textHunks } from "coplan/merge_text"

// The view blocks open in: the reader's choice under Settings → Appearance.
export function defaultMarkdownBlockView() {
  return document.documentElement.dataset.markdownBlockView === "source" ? "source" : "rendered"
}

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

// Only blocks switched away from the default need restoring; the rest open
// in the default when their controller connects.
export function restoreMarkdownBlockViews(root, previous) {
  const fallback = defaultMarkdownBlockView()
  if (!previous.blocks.some(block => block.view !== fallback)) return
  const current = captureMarkdownBlockViews(root)
  const hunks = textHunks(previous.text, current.text)
  for (const block of previous.blocks) {
    if (block.view === fallback || block.from === null) continue
    // Score surviving text through the diff, rather than trusting one
    // boundary: an insertion may share its first characters with the draft.
    const scores = new Map()
    let cursor = 0, delta = 0
    for (const hunk of [...hunks, { from: previous.text.length, to: previous.text.length, text: "" }]) {
      const from = Math.max(block.from, cursor) + delta
      const to = Math.min(block.to, hunk.from) + delta
      if (to > from) for (const candidate of current.blocks) {
        const overlap = Math.max(0, Math.min(to, candidate.to) - Math.max(from, candidate.from))
        scores.set(candidate, (scores.get(candidate) || 0) + overlap)
      }
      delta += hunk.text.length - (hunk.to - hunk.from)
      cursor = hunk.to
    }
    const identical = current.blocks.filter(candidate => candidate.source.textContent === block.source.textContent)
    const mapped = [...scores].sort((a, b) => b[1] - a[1])[0]
    const match = mapped?.[1] > 0 ? mapped[0] : (identical.length === 1 ? identical[0] : null)
    if (!match) continue
    const element = match.source.parentElement
    const source = block.view === "source"
    element.dataset.view = block.view
    match.source.hidden = !source
    element.querySelector(":scope > [data-markdown-block-rendered]").hidden = source
    element.querySelectorAll("button[data-view]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.view === block.view)))
  }
}
