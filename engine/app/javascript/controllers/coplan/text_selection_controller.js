import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "popover", "form", "anchorInput", "contextInput", "occurrenceInput", "anchorPreview", "anchorQuote", "margin", "threads"]
  static values = { planId: String }

  connect() {
    this.selectedText = null
    this.contentTarget.addEventListener("mouseup", this.handleMouseUp.bind(this))
    document.addEventListener("mousedown", this.handleDocumentMouseDown.bind(this))
    this.highlightAnchors()

    // Watch for broadcast-appended threads and re-highlight
    if (this.hasThreadsTarget) {
      this._threadsObserver = new MutationObserver(() => this.highlightAnchors())
      this._threadsObserver.observe(this.threadsTarget, { childList: true })
    }
  }

  disconnect() {
    this.contentTarget.removeEventListener("mouseup", this.handleMouseUp.bind(this))
    document.removeEventListener("mousedown", this.handleDocumentMouseDown.bind(this))
    if (this._threadsObserver) {
      this._threadsObserver.disconnect()
      this._threadsObserver = null
    }
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

    if (!selection.rangeCount) return
    const range = selection.getRangeAt(0)

    // Make sure at least part of the selection is within the content area.
    // Whole-line selections (e.g. triple-click) can set commonAncestorContainer
    // to a parent element above contentTarget, so we check start/end individually.
    const startInContent = this.contentTarget.contains(range.startContainer)
    const endInContent = this.contentTarget.contains(range.endContainer)
    if (!startInContent) {
      return
    }

    // Clamp the range to the last rendered markdown element, not the
    // content wrapper's lastChild (which is a hidden popover/form control).
    if (startInContent && !endInContent) {
      const clampTarget = this.hasPopoverTarget
        ? this.popoverTarget.previousElementSibling || this.popoverTarget.previousSibling
        : this.contentTarget.lastChild
      if (clampTarget) range.setEndAfter(clampTarget)
    }

    // Extract text after clamping so it only contains content-area text
    const text = selection.toString().trim()

    if (text.length < 3) {
      this.popoverTarget.style.display = "none"
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

    // Position form where the popover was, then show it
    this.formTarget.style.top = this.popoverTarget.style.top
    this.formTarget.style.left = this.popoverTarget.style.left
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
      if (textarea) {
        textarea.value = ""
        textarea.blur()
      }
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

  openThreadPopover(event) {
    const threadId = event.currentTarget.dataset.threadId
    if (!threadId) return

    const popover = document.getElementById(`${threadId}_popover`)
    if (!popover) return

    // Position the popover near the clicked element
    const trigger = event.currentTarget
    const triggerRect = trigger.getBoundingClientRect()

    // Hide visually while positioning to prevent flash
    popover.style.visibility = "hidden"
    popover.showPopover()

    // Position after showing (popover needs to be in top layer first)
    const popoverRect = popover.getBoundingClientRect()
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight

    // Default: right of the content area, aligned with the trigger
    let top = triggerRect.top
    let left = triggerRect.right + 12

    // If it would overflow right, position to the left
    if (left + popoverRect.width > viewportWidth - 16) {
      left = triggerRect.left - popoverRect.width - 12
    }

    // If it would overflow bottom, shift up
    if (top + popoverRect.height > viewportHeight - 16) {
      top = viewportHeight - popoverRect.height - 16
    }

    // Ensure it doesn't go outside viewport
    if (top < 16) top = 16
    if (left < 16) left = 16

    popover.style.top = `${top}px`
    popover.style.left = `${left}px`
    popover.style.visibility = "visible"
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

    // Clear margin dots
    if (this.hasMarginTarget) {
      this.marginTarget.innerHTML = ""
    }

    // Build full text once for position lookups
    this.fullText = this.contentTarget.textContent

    const threads = this.element.querySelectorAll("[data-anchor-text]")
    threads.forEach(thread => {
      const anchor = thread.dataset.anchorText
      const occurrence = thread.dataset.anchorOccurrence
      const status = thread.dataset.threadStatus || "pending"
      const threadId = thread.id

      if (anchor && anchor.length > 0) {
        const isOpen = status === "pending" || status === "todo"
        const statusClass = isOpen ? "anchor-highlight--open" : "anchor-highlight--resolved"
        const mark = this.findAndHighlight(anchor, occurrence, `anchor-highlight ${statusClass}`)

        if (mark && threadId) {
          // Make highlight clickable to open popover
          mark.dataset.threadId = threadId
          mark.style.cursor = "pointer"
          mark.addEventListener("click", (e) => this.openThreadPopover(e))

          // Create margin dot
          if (this.hasMarginTarget) {
            this.createMarginDot(mark, threadId, status)
          }
        }
      }
    })
  }

  createMarginDot(highlightMark, threadId, status) {
    const contentRect = this.contentTarget.getBoundingClientRect()
    const markRect = highlightMark.getBoundingClientRect()
    const marginRect = this.marginTarget.getBoundingClientRect()

    const dot = document.createElement("button")
    const isOpen = status === "pending" || status === "todo"
    dot.className = `margin-dot margin-dot--${isOpen ? "open" : "resolved"}`
    dot.style.top = `${markRect.top - marginRect.top}px`
    dot.dataset.threadId = threadId
    dot.addEventListener("click", (e) => this.openThreadPopover(e))
    dot.title = `${status} comment`

    this.marginTarget.appendChild(dot)
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
