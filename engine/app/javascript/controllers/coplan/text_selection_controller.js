import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "popover", "form", "anchorInput", "contextInput", "occurrenceInput", "anchorPreview", "anchorQuote"]
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
    this.selectedOccurrence = this.computeOccurrence(range, text)

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

    // Set the anchor text, surrounding context, and occurrence index
    this.anchorInputTarget.value = this.selectedText
    this.contextInputTarget.value = this.selectedContext || ""
    this.occurrenceInputTarget.value = this.selectedOccurrence != null ? this.selectedOccurrence : ""
    this.anchorQuoteTarget.textContent = this.selectedText.length > 120
      ? this.selectedText.substring(0, 120) + "…"
      : this.selectedText
    this.anchorPreviewTarget.style.display = "block"

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
    this.occurrenceInputTarget.value = ""
    this.anchorPreviewTarget.style.display = "none"
    const textarea = this.formTarget.querySelector("textarea")
    if (textarea) textarea.value = ""
    this.selectedText = null
    this.selectedContext = null
    this.selectedOccurrence = null
  }

  scrollToAnchor(event) {
    const anchor = event.currentTarget.dataset.anchor
    if (!anchor) return

    const occurrence = event.currentTarget.dataset.anchorOccurrence

    // Remove existing highlights first
    this.contentTarget.querySelectorAll(".anchor-highlight--active").forEach(el => {
      el.classList.remove("anchor-highlight--active")
    })

    // Build full text for position lookups
    this.fullText = this.contentTarget.textContent

    const highlighted = this.findAndHighlight(anchor, occurrence, "anchor-highlight--active")
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

  // Computes the 1-based occurrence number of the selected text in the DOM content.
  // This is sent to the server so resolve_anchor_position picks the right match.
  computeOccurrence(range, text) {
    const offset = this.getSelectionOffset(range)
    const fullText = this.contentTarget.textContent

    let count = 0
    let pos = -1
    while ((pos = fullText.indexOf(text, pos + 1)) !== -1) {
      count++
      if (pos >= offset) return count
    }
    return count > 0 ? count : 1
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
    // Remove existing anchor highlights before re-highlighting
    this.contentTarget.querySelectorAll("mark.anchor-highlight").forEach(mark => {
      const parent = mark.parentNode
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark)
      parent.removeChild(mark)
    })
    this.contentTarget.normalize()

    // Build full text once for position lookups
    this.fullText = this.contentTarget.textContent

    const threads = this.element.querySelectorAll("[data-anchor-text]")
    threads.forEach(thread => {
      const anchor = thread.dataset.anchorText
      const occurrence = thread.dataset.anchorOccurrence
      if (anchor && anchor.length > 0) {
        this.findAndHighlight(anchor, occurrence, "anchor-highlight")
      }
    })
  }

  // Find and highlight the Nth occurrence of text in the rendered DOM.
  // Uses the occurrence index from server-side positional data.
  findAndHighlight(text, occurrence, className) {
    const fullText = this.fullText
    let targetIndex = -1

    if (occurrence !== undefined && occurrence !== "") {
      const occurrenceNum = parseInt(occurrence, 10)
      if (!isNaN(occurrenceNum)) {
        targetIndex = this.findNthOccurrence(fullText, text, occurrenceNum)
      }
    }

    if (targetIndex === -1) return null

    return this.highlightAtIndex(targetIndex, text.length, className)
  }

  findNthOccurrence(text, search, n) {
    let pos = -1
    for (let i = 0; i <= n; i++) {
      pos = text.indexOf(search, pos + 1)
      if (pos === -1) return -1
    }
    return pos
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
}
