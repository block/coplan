import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "popover", "form", "anchorInput", "contextInput", "anchorPreview", "anchorQuote"]
  static values = { planId: String }

  connect() {
    this.selectedText = null
    this.contentTarget.addEventListener("mouseup", this.handleMouseUp.bind(this))
    document.addEventListener("mousedown", this.handleDocumentMouseDown.bind(this))
    this.highlightAnchors()
  }

  disconnect() {
    this.contentTarget.removeEventListener("mouseup", this.handleMouseUp.bind(this))
    document.removeEventListener("mousedown", this.handleDocumentMouseDown.bind(this))
  }

  handleMouseUp(event) {
    // Small delay to let the selection finalize
    setTimeout(() => this.checkSelection(event), 10)
  }

  handleDocumentMouseDown(event) {
    // Hide popover if clicking outside it
    if (this.hasPopoverTarget && !this.popoverTarget.contains(event.target)) {
      this.popoverTarget.style.display = "none"
    }
  }

  checkSelection(event) {
    const selection = window.getSelection()
    const text = selection.toString().trim()

    if (text.length < 3) {
      this.popoverTarget.style.display = "none"
      return
    }

    // Make sure selection is within the content area
    if (!selection.rangeCount) return
    const range = selection.getRangeAt(0)
    if (!this.contentTarget.contains(range.commonAncestorContainer)) {
      return
    }

    this.selectedText = text
    this.selectedContext = this.extractContext(range, text)

    // Position popover near the selection
    const rect = range.getBoundingClientRect()
    const contentRect = this.contentTarget.getBoundingClientRect()

    this.popoverTarget.style.display = "block"
    this.popoverTarget.style.top = `${rect.bottom - contentRect.top + 8}px`
    this.popoverTarget.style.left = `${rect.left - contentRect.left}px`
  }

  openCommentForm(event) {
    event.preventDefault()
    if (!this.selectedText) return

    // Set the anchor text and surrounding context
    this.anchorInputTarget.value = this.selectedText
    this.contextInputTarget.value = this.selectedContext || ""
    this.anchorQuoteTarget.textContent = this.selectedText.length > 120
      ? this.selectedText.substring(0, 120) + "…"
      : this.selectedText
    this.anchorPreviewTarget.style.display = "block"

    // Position the form in the sidebar at the same vertical level as the selection
    const layoutRect = this.element.getBoundingClientRect()
    const popoverRect = this.popoverTarget.getBoundingClientRect()
    const offsetTop = popoverRect.top - layoutRect.top
    this.formTarget.style.position = "absolute"
    this.formTarget.style.top = `${offsetTop}px`

    // Show form, hide popover
    this.formTarget.style.display = "block"
    this.popoverTarget.style.display = "none"

    // Clear browser selection
    window.getSelection().removeAllRanges()

    // Focus textarea without scrolling the page
    const textarea = this.formTarget.querySelector("textarea")
    if (textarea) {
      textarea.focus({ preventScroll: true })
    }
  }

  cancelComment(event) {
    event.preventDefault()
    this.hideAndResetForm()
  }

  resetCommentForm(event) {
    if (event.detail.success) {
      this.hideAndResetForm()
      // Re-highlight anchors and reposition threads after the broadcast adds the new thread
      setTimeout(() => {
        this.highlightAnchors()
      }, 100)
    }
  }

  resetReplyForm(event) {
    if (event.detail.success) {
      const form = event.target
      const textarea = form.querySelector("textarea")
      if (textarea) textarea.value = ""
    }
  }

  hideAndResetForm() {
    this.formTarget.style.display = "none"
    this.anchorInputTarget.value = ""
    this.contextInputTarget.value = ""
    this.anchorPreviewTarget.style.display = "none"
    const textarea = this.formTarget.querySelector("textarea")
    if (textarea) textarea.value = ""
    this.selectedText = null
    this.selectedContext = null
  }

  scrollToAnchor(event) {
    const anchor = event.currentTarget.dataset.anchor
    if (!anchor) return

    const context = event.currentTarget.closest("[data-anchor-context]")?.dataset.anchorContext || ""

    // Remove existing highlights first
    this.contentTarget.querySelectorAll(".anchor-highlight--active").forEach(el => {
      el.classList.remove("anchor-highlight--active")
    })

    // Find and highlight the anchor text using context for disambiguation
    const highlighted = context
      ? this.findAndHighlightWithContext(anchor, context, "anchor-highlight--active")
      : this.findAndHighlight(anchor, "anchor-highlight--active")
    if (highlighted) {
      highlighted.scrollIntoView({ behavior: "smooth", block: "center" })
    }
  }

  extractContext(range, selectedText) {
    // Grab surrounding text for disambiguation
    const fullText = this.contentTarget.textContent
    const selIndex = fullText.indexOf(selectedText)
    if (selIndex === -1) return ""

    // Find ALL occurrences — if unique, no context needed
    let count = 0
    let pos = -1
    while ((pos = fullText.indexOf(selectedText, pos + 1)) !== -1) count++
    if (count === 1) return ""

    // Multiple occurrences — find which one by using the range's position
    // Grab ~100 chars before and after for a unique context
    const contextBefore = 100
    const contextAfter = 100

    // Use a DOM-based walk to figure out the offset in the text content
    const offset = this.getSelectionOffset(range)

    const start = Math.max(0, offset - contextBefore)
    const end = Math.min(fullText.length, offset + selectedText.length + contextAfter)
    return fullText.slice(start, end)
  }

  getSelectionOffset(range) {
    if (!range || !this.contentTarget) return 0

    const walker = document.createTreeWalker(this.contentTarget, NodeFilter.SHOW_TEXT, null)
    let offset = 0
    let node

    while ((node = walker.nextNode())) {
      if (range.startContainer === node) {
        offset += range.startOffset
        break
      }
      offset += node.textContent.length
    }

    return offset
  }

  highlightAnchors() {
    // Build full text once for position lookups
    this.fullText = this.contentTarget.textContent

    const threads = this.element.querySelectorAll("[data-anchor-text]")
    threads.forEach(thread => {
      const anchor = thread.dataset.anchorText
      const context = thread.dataset.anchorContext
      if (anchor && anchor.length > 0) {
        this.findAndHighlightWithContext(anchor, context, "anchor-highlight")
      }
    })

    this.positionThreads()
  }

  repositionThreads() {
    // Small delay to let the tab panel become visible before measuring positions
    setTimeout(() => this.positionThreads(), 10)
  }

  positionThreads() {
    const sidebar = this.element.querySelector(".plan-layout__sidebar")
    if (!sidebar) return

    this.positionThreadList("#comment-threads", sidebar)
    this.positionThreadList("#resolved-comment-threads", sidebar)
  }

  positionThreadList(selector, sidebar) {
    const threadList = this.element.querySelector(selector)
    if (!threadList) return

    const threads = Array.from(threadList.querySelectorAll(".comment-thread"))
    if (threads.length === 0) return

    const sidebarRect = sidebar.getBoundingClientRect()

    // Sort threads by their anchor's vertical position in the document
    threads.sort((a, b) => {
      const markA = a._highlightMark
      const markB = b._highlightMark
      const yA = markA ? markA.getBoundingClientRect().top : Infinity
      const yB = markB ? markB.getBoundingClientRect().top : Infinity
      return yA - yB
    })

    // Reorder DOM within this list only
    threads.forEach(thread => threadList.appendChild(thread))

    // Position threads vertically
    const gap = 8
    let cursor = 0

    threads.forEach(thread => {
      const mark = thread._highlightMark
      let desiredY = cursor

      if (mark) {
        desiredY = mark.getBoundingClientRect().top - sidebarRect.top + sidebar.scrollTop
      }

      const y = Math.max(desiredY, cursor)
      thread.style.marginTop = `${y - cursor}px`
      cursor = y + thread.offsetHeight + gap
    })
  }

  findAndHighlightWithContext(text, context, className) {
    // Use context to find the right occurrence of the anchor text
    const fullText = this.fullText
    let targetIndex

    if (context && context.length > 0) {
      const contextIndex = fullText.indexOf(context)
      if (contextIndex !== -1) {
        // Find the anchor text within the context region
        targetIndex = fullText.indexOf(text, contextIndex)
        if (targetIndex === -1 || targetIndex > contextIndex + context.length) {
          targetIndex = fullText.indexOf(text) // fallback
        }
      } else {
        targetIndex = fullText.indexOf(text)
      }
    } else {
      targetIndex = fullText.indexOf(text)
    }

    if (targetIndex === -1) return null

    // Find the thread element to store the mark reference
    const threads = this.element.querySelectorAll(".comment-thread[data-anchor-text]")
    let threadEl = null
    for (const t of threads) {
      if (t.dataset.anchorText === text && t.dataset.anchorContext === (context || "")) {
        threadEl = t
        break
      }
    }

    const mark = this.highlightAtIndex(targetIndex, text.length, className)
    if (mark && threadEl) threadEl._highlightMark = mark
    return mark
  }

  highlightAtIndex(startIndex, length, className) {
    if (startIndex < 0 || length <= 0) return null

    const walker = document.createTreeWalker(
      this.contentTarget,
      NodeFilter.SHOW_TEXT,
      null,
      false
    )

    const textNodes = []
    let fullText = ""
    let node
    while (node = walker.nextNode()) {
      textNodes.push({ node, start: fullText.length })
      fullText += node.textContent
    }

    const matchEnd = startIndex + length
    let firstHighlighted = null

    for (let i = 0; i < textNodes.length; i++) {
      const tn = textNodes[i]
      const nodeEnd = tn.start + tn.node.textContent.length

      if (nodeEnd <= startIndex) continue
      if (tn.start >= matchEnd) break

      const localStart = Math.max(0, startIndex - tn.start)
      const localEnd = Math.min(tn.node.textContent.length, matchEnd - tn.start)

      const range = document.createRange()
      range.setStart(tn.node, localStart)
      range.setEnd(tn.node, localEnd)

      const mark = document.createElement("mark")
      mark.className = className
      range.surroundContents(mark)

      if (!firstHighlighted) firstHighlighted = mark
    }

    return firstHighlighted
  }

  // Keep legacy method for scrollToAnchor (single-use highlight)
  findAndHighlight(text, className) {
    if (!text || text.length === 0) return null
    const fullText = this.contentTarget.textContent
    const index = fullText.indexOf(text)
    if (index === -1) return null
    return this.highlightAtIndex(index, text.length, className)
  }
}
