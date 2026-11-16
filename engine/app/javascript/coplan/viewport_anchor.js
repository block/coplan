const BLOCKS = ".markdown-rendered h1, .markdown-rendered h2, .markdown-rendered h3, .markdown-rendered p, .markdown-rendered li, .ProseMirror h1, .ProseMirror h2, .ProseMirror h3, .ProseMirror p, .ProseMirror li, .markdown-rendered pre, .ProseMirror pre"

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
  return captureBlockViewport(root, block, block.getBoundingClientRect().top)
}

export function captureBlockViewport(root, element, top, offset) {
  const block = (element.nodeType === Node.ELEMENT_NODE ? element : element.parentElement)?.closest(BLOCKS)
  if (!block || !root.contains(block)) return null
  const blocks = Array.from(root.querySelectorAll(BLOCKS))
  const text = textOf(block)
  let textOffset
  if (offset !== undefined) {
    const range = document.createRange()
    range.selectNodeContents(block)
    range.setEnd(element, offset)
    textOffset = range.toString().length
  }
  return {
    text, index: blocks.indexOf(block),
    occurrence: text ? blocks.slice(0, blocks.indexOf(block)).filter(element => textOf(element) === text).length : 0,
    top, textOffset, rootTop: root.getBoundingClientRect().top
  }
}

export function restoreViewport(root, anchor) {
  if (!anchor) return
  const blocks = Array.from(root.querySelectorAll(BLOCKS))
  const matches = anchor.text ? blocks.filter(element => textOf(element) === anchor.text) : []
  const target = matches[anchor.occurrence] || blocks[Math.min(anchor.index, blocks.length - 1)]
  let newTop = target?.getBoundingClientRect().top ?? root.getBoundingClientRect().top
  if (target && anchor.textOffset !== undefined) {
    const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT)
    let remaining = anchor.textOffset, node
    while ((node = walker.nextNode())) {
      if (remaining > node.length) { remaining -= node.length; continue }
      const range = document.createRange()
      range.setStart(node, remaining)
      range.collapse(true)
      const rect = range.getBoundingClientRect()
      if (rect.height) newTop = rect.top
      break
    }
  }
  const oldTop = target ? anchor.top : anchor.rootTop
  if (Number.isFinite(oldTop)) window.scrollBy(0, newTop - oldTop)
}
