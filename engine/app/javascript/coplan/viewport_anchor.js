const BLOCKS = ".markdown-rendered h1, .markdown-rendered h2, .markdown-rendered h3, .markdown-rendered p, .markdown-rendered li, .ProseMirror h1, .ProseMirror h2, .ProseMirror h3, .ProseMirror p, .ProseMirror li"

const textOf = element => element.textContent.replace(/\s+/g, " ").trim()

// Track a visible passage rather than a document-wide pixel offset. Remote
// inserts and the read/edit DOM switch may change heights above the viewport.
export function captureViewport(root) {
  const blocks = Array.from(root.querySelectorAll(BLOCKS))
  const line = Math.min(160, window.innerHeight / 3)
  const block = blocks.find(element => {
    const rect = element.getBoundingClientRect()
    return rect.bottom > line && rect.top < window.innerHeight
  })
  if (!block) return null
  const text = textOf(block)
  return {
    text, index: blocks.indexOf(block),
    occurrence: text ? blocks.slice(0, blocks.indexOf(block)).filter(element => textOf(element) === text).length : 0,
    top: block.getBoundingClientRect().top, rootTop: root.getBoundingClientRect().top
  }
}

export function restoreViewport(root, anchor) {
  if (!anchor) return
  const blocks = Array.from(root.querySelectorAll(BLOCKS))
  const matches = anchor.text ? blocks.filter(element => textOf(element) === anchor.text) : []
  const target = matches[anchor.occurrence] || blocks[Math.min(anchor.index, blocks.length - 1)]
  const newTop = target?.getBoundingClientRect().top ?? root.getBoundingClientRect().top
  const oldTop = target ? anchor.top : anchor.rootTop
  if (Number.isFinite(oldTop)) window.scrollBy(0, newTop - oldTop)
}
