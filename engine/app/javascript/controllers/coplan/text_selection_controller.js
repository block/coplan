import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "popover", "form", "anchorInput", "contextInput", "occurrenceInput", "anchorPreview", "anchorQuote", "threads"]
  static values = { planId: String, focusThread: String }

  connect() {
    this.selectedText = null
    this._activeMark = null
    this._activePopover = null
    this._boundHandleMouseUp = this.handleMouseUp.bind(this)
    this._boundHandleDocumentMouseDown = this.handleDocumentMouseDown.bind(this)
    this._handleScroll = this._handleScroll.bind(this)
    this.contentTarget.addEventListener("mouseup", this._boundHandleMouseUp)
    document.addEventListener("mousedown", this._boundHandleDocumentMouseDown)
    window.addEventListener("scroll", this._handleScroll, { passive: true })
    this.highlightAnchors()

    // Watch for broadcast-appended threads and re-highlight
    if (this.hasThreadsTarget) {
      this._threadsObserver = new MutationObserver(() => this.highlightAnchors())
      this._threadsObserver.observe(this.threadsTarget, { childList: true })
    }

    // Auto-open a specific thread if linked via ?thread=ID (set as a Stimulus value)
    if (this.focusThreadValue) {
      this._pendingThreadId = this.focusThreadValue
      this.focusThreadValue = ""
      this._openLinkedThread()
    }
  }

  disconnect() {
    this.contentTarget.removeEventListener("mouseup", this._boundHandleMouseUp)
    document.removeEventListener("mousedown", this._boundHandleDocumentMouseDown)
    window.removeEventListener("scroll", this._handleScroll)
    if (this._threadsObserver) {
      this._threadsObserver.disconnect()
      this._threadsObserver = null
    }
  }

  handleMouseUp(event) {
    // Small delay to let the selection finalize
    setTimeout(() => this.checkSelection(event), 10)
  }

  dismiss(event) {
    // Close the comment form if it's visible
    if (this.hasFormTarget && this.formTarget.style.display === "block") {
      event.preventDefault()
      this.hideAndResetForm()
      return
    }
    // Close the selection popover if it's visible
    if (this.hasPopoverTarget && this.popoverTarget.style.display === "block") {
      event.preventDefault()
      this.popoverTarget.style.display = "none"
    }
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

    // Extract text after clamping so it only contains content-area text.
    // Normalize tabs to spaces — browser selections across table cells
    // produce tab-separated text, but the server matches against
    // space-separated plain text extracted from the markdown AST.
    const text = selection.toString().replace(/\t/g, " ").trim()

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

    const trigger = event.currentTarget

    popover.style.visibility = "hidden"
    popover.showPopover()
    this._positionPopoverAtMark(popover, trigger)
    popover.style.visibility = "visible"

    this._activeMark = trigger
    this._activePopover = popover
  }

  _handleScroll() {
    if (!this._activeMark || !this._activePopover) return
    try {
      if (!this._activePopover.matches(":popover-open")) {
        this._activeMark = null
        this._activePopover = null
        return
      }
    } catch { return }
    this._positionPopoverAtMark(this._activePopover, this._activeMark)
  }

  _positionPopoverAtMark(popover, mark) {
    const markRect = mark.getBoundingClientRect()
    const popoverRect = popover.getBoundingClientRect()
    const viewportWidth = window.innerWidth
    const viewportHeight = window.innerHeight

    let top = markRect.top
    let left = markRect.right + 12

    if (left + popoverRect.width > viewportWidth - 16) {
      left = markRect.left - popoverRect.width - 12
    }
    if (top + popoverRect.height > viewportHeight - 16) {
      top = viewportHeight - popoverRect.height - 16
    }
    if (top < 16) top = 16
    if (left < 16) left = 16

    popover.style.top = `${top}px`
    popover.style.left = `${left}px`
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
  // Uses whitespace-normalized matching for consistency with findAndHighlight.
  computeOccurrence(range, text) {
    const offset = this.getSelectionOffset(range)
    const fullText = this.contentTarget.textContent
    const { normText, origIndices } = this._buildNormalizedMap(fullText)
    const normSearch = this._normalizeWhitespace(text)

    // Map the DOM offset to the normalized string offset
    let normOffset = origIndices.findIndex(orig => orig >= offset)
    if (normOffset === -1) normOffset = normText.length

    let count = 0
    let pos = -1
    while ((pos = normText.indexOf(normSearch, pos + 1)) !== -1) {
      count++
      if (pos >= normOffset) return count
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
      const status = thread.dataset.threadStatus || "pending"
      const threadId = thread.id

      if (anchor && anchor.length > 0) {
        const isOpen = status === "pending" || status === "todo"
        const statusClass = isOpen ? "anchor-highlight--open" : "anchor-highlight--resolved"
        const specificClass = isOpen ? `anchor-highlight--${status}` : ""
        const classes = `anchor-highlight ${statusClass} ${specificClass}`.trim()
        const marks = this.findAndHighlightAll(anchor, occurrence, classes)

        if (marks.length > 0 && threadId) {
          marks.forEach(mark => {
            if (!mark.dataset.threadId) {
              mark.dataset.threadId = threadId
              mark.style.cursor = "pointer"
              mark.addEventListener("click", (e) => this.openThreadPopover(e))
            }
          })
        }
      }
    })

    this.element.dispatchEvent(new CustomEvent("coplan:anchors-updated", { bubbles: true }))
  }

  // Find and highlight the Nth occurrence of text in the rendered DOM.
  // Uses the occurrence index from server-side positional data.
  // Performs whitespace-normalized matching so that anchor text captured
  // from browser selections (which may differ in whitespace from the DOM
  // textContent, e.g. tabs in table selections) can still be located.
  findAndHighlight(text, occurrence, className) {
    const fullText = this.fullText

    if (occurrence === undefined || occurrence === "") return null

    const occurrenceNum = parseInt(occurrence, 10)
    if (isNaN(occurrenceNum)) return null

    const match = this._findNthNormalized(fullText, text, occurrenceNum)
    if (!match) return null

    return this.highlightAtIndex(match.startIndex, match.matchLength, className)
  }

  // Like findAndHighlight but returns all created/reused marks (for multi-cell spans).
  findAndHighlightAll(text, occurrence, className) {
    const fullText = this.fullText

    if (occurrence === undefined || occurrence === "") return []

    const occurrenceNum = parseInt(occurrence, 10)
    if (isNaN(occurrenceNum)) return []

    const match = this._findNthNormalized(fullText, text, occurrenceNum)
    if (!match) return []

    return this.highlightAtIndexAll(match.startIndex, match.matchLength, className)
  }

  // Collapses runs of whitespace (spaces, tabs, newlines) into single spaces.
  _normalizeWhitespace(str) {
    return str.replace(/\s+/g, " ")
  }

  // Builds a whitespace-normalized version of `text` with a parallel array
  // mapping each normalized position back to its original index.
  // Returns { normText, origIndices } where origIndices[i] is the original
  // index of the character at normalized position i.
  _buildNormalizedMap(text) {
    let normText = ""
    const origIndices = []
    let inWhitespace = false

    for (let i = 0; i < text.length; i++) {
      if (/\s/.test(text[i])) {
        if (!inWhitespace) {
          normText += " "
          origIndices.push(i)
          inWhitespace = true
        }
      } else {
        normText += text[i]
        origIndices.push(i)
        inWhitespace = false
      }
    }

    return { normText, origIndices }
  }

  // Finds the Nth occurrence of `search` in `text` using whitespace-normalized
  // matching. Returns { startIndex, matchLength } in the *original* text,
  // or null if not found.
  _findNthNormalized(text, search, n) {
    const { normText, origIndices } = this._buildNormalizedMap(text)
    const normSearch = this._normalizeWhitespace(search)

    let pos = -1
    for (let i = 0; i <= n; i++) {
      pos = normText.indexOf(normSearch, pos + 1)
      if (pos === -1) return null
    }

    const origStart = origIndices[pos]
    const origEnd = origIndices[pos + normSearch.length - 1] + 1
    return { startIndex: origStart, matchLength: origEnd - origStart }
  }

  _openLinkedThread(attempt = 0) {
    const threadId = this._pendingThreadId
    if (!threadId) return

    const domId = `comment_thread_${threadId}`
    const mark = this.contentTarget.querySelector(`mark[data-thread-id="${domId}"]`)
    if (mark) {
      this._pendingThreadId = null
      requestAnimationFrame(() => {
        mark.scrollIntoView({ behavior: "instant", block: "center" })
        this.openThreadPopover({ currentTarget: mark })
      })
      return
    }

    // Marks may not exist yet (Turbo Drive render timing).
    // Retry a few times with increasing delay.
    if (attempt < 10) {
      setTimeout(() => this._openLinkedThread(attempt + 1), 100)
    }
  }

  highlightAtIndex(startIndex, length, className) {
    const marks = this.highlightAtIndexAll(startIndex, length, className)
    return marks[0] || null
  }

  highlightAtIndexAll(startIndex, length, className) {
    if (startIndex < 0 || length <= 0) return []

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
    const marks = []

    for (let i = 0; i < textNodes.length; i++) {
      const tn = textNodes[i]
      const nodeEnd = tn.start + tn.node.textContent.length

      if (nodeEnd <= startIndex) continue
      if (tn.start >= matchEnd) break

      // Skip structural whitespace text nodes inside table elements —
      // wrapping these in <mark> produces invalid HTML and breaks table layout.
      const parentTag = tn.node.parentElement?.tagName
      if (parentTag && /^(TABLE|THEAD|TBODY|TFOOT|TR)$/.test(parentTag)) continue

      const localStart = Math.max(0, startIndex - tn.start)
      const localEnd = Math.min(tn.node.textContent.length, matchEnd - tn.start)

      // Skip zero-length ranges (e.g. from text node splits by prior highlights)
      if (localEnd <= localStart) continue

      // If the text is already inside a highlight mark (from another thread
      // anchored to the same text), reuse that mark instead of nesting.
      const existingMark = tn.node.parentElement?.closest("mark.anchor-highlight")
      if (existingMark) {
        if (!marks.includes(existingMark)) marks.push(existingMark)
        continue
      }

      const range = document.createRange()
      range.setStart(tn.node, localStart)
      range.setEnd(tn.node, localEnd)

      const mark = document.createElement("mark")
      mark.className = className
      range.surroundContents(mark)

      marks.push(mark)
    }

    return marks
  }
}
