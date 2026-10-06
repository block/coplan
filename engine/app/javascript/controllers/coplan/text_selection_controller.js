import { Controller } from "@hotwired/stimulus"

// Elements whose text is never rendered but still appears in textContent —
// e.g. the <style> sheet Mermaid embeds inside its SVG. Their text must stay
// out of the anchor text model (capture, occurrence counting, highlighting):
// wrapping a <mark> inside a <style> re-parents part of the CSS out of the
// sheet (a <style> only parses its direct child text), which strips the
// diagram's styling and renders it as unstyled black shapes.
const NON_RENDERED_TEXT_SELECTOR = "style, script, noscript, [data-source-badge]"

export default class extends Controller {
  static targets = ["content", "popover", "form", "anchorInput", "contextInput", "occurrenceInput", "anchorPreview", "anchorQuote", "threads"]
  static values = { focusThread: String }

  connect() {
    this.selectedText = null
    this._activeMark = null
    this._activePopover = null
    this._boundHandleMouseUp = this.handleMouseUp.bind(this)
    this._boundHandleDocumentMouseDown = this.handleDocumentMouseDown.bind(this)
    this._handleScroll = this._handleScroll.bind(this)
    // Close the comment form before Turbo snapshots the page: a cached
    // copy would otherwise restore with popover="manual" + display:block
    // but outside the top layer — a mispositioned form with stale anchor
    // inputs.
    this._boundBeforeCache = () => { if (this.hasFormTarget) this.hideAndResetForm() }
    document.addEventListener("turbo:before-cache", this._boundBeforeCache)
    this._boundPopoverToggle = this._handlePopoverToggle.bind(this)
    this.contentTarget.addEventListener("mouseup", this._boundHandleMouseUp)
    document.addEventListener("mousedown", this._boundHandleDocumentMouseDown)
    // Captured on the document rather than bound to `window`: a `scroll`
    // event from a nested scroller — a data table's frame, the expanded
    // sheet — does not bubble, so a window listener never hears it and an
    // open popover sits still while the mark it points at scrolls away.
    // Capture at the document sees both, and the handler returns
    // immediately unless a popover is actually open.
    document.addEventListener("scroll", this._handleScroll, { capture: true, passive: true })
    this.highlightAnchors()

    // Watch for broadcast-appended threads and re-highlight
    if (this.hasThreadsTarget) {
      this._threadsObserver = new MutationObserver(() => { this.highlightAnchors(); this.refreshEditorPreviews() })
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
    document.removeEventListener("turbo:before-cache", this._boundBeforeCache)
    document.removeEventListener("scroll", this._handleScroll, { capture: true })
    clearTimeout(this._linkedThreadRetry)
    if (this._threadsObserver) {
      this._threadsObserver.disconnect()
      this._threadsObserver = null
    }
  }

  handleMouseUp(event) {
    // Small delay to let the selection finalize
    setTimeout(() => this.checkSelection(event), 10)
  }

  handleEditorMouseUp(event) {
    const editor = event.currentTarget.querySelector(".ProseMirror")
    if (!editor) return
    // The selection is usually complete at mouseup. Read it now so an
    // editor redraw cannot clear it during the delayed fallback.
    const selection = window.getSelection()
    if (selection?.rangeCount && !selection.isCollapsed && editor.contains(selection.getRangeAt(0).startContainer)) this.checkSelection(event, editor)
    else setTimeout(() => this.checkSelection(event, editor), 10)
  }

  dismiss(event) {
    // Let native Escape dismiss the topmost microphone menu first.
    if (event?.key === "Escape" && document.querySelector(".microphone-settings__panel:popover-open")) return
    // Close the comment form if it's visible
    if (this.hasFormTarget && this.formTarget.matches(":popover-open")) {
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

  checkSelection(event, root = this.contentTarget) {
    const selection = window.getSelection()

    if (!selection.rangeCount) return
    const range = selection.getRangeAt(0)

    // Make sure at least part of the selection is within the content area.
    // Whole-line selections (e.g. triple-click) can set commonAncestorContainer
    // to a parent element above contentTarget, so we check start/end individually.
    const startInContent = root.contains(range.startContainer)
    const endInContent = root.contains(range.endContainer)
    if (!startInContent) {
      return
    }

    // Clamp the range to the last rendered markdown element. The selection
    // popover lives outside this wrapper so it also works while editing.
    if (root === this.contentTarget && startInContent && !endInContent) {
      const clampTarget = root.lastElementChild || root.lastChild
      if (clampTarget) range.setEndAfter(clampTarget)
    }

    // Extract text from the range's cloneContents() so it matches the
    // rendered text model (used for occurrence lookup and highlighting).
    // selection.toString() can differ — e.g. tables produce tab-separated
    // text via toString() but not via textContent. Drop non-rendered text
    // first: a selection swept across a Mermaid diagram invisibly picks up
    // its SVG <style> sheet, and an anchor carrying that CSS re-corrupts
    // the diagram on every future visit.
    // Normalize whitespace (collapse runs of spaces/tabs/newlines) so the
    // stored anchor_text matches the server-side canonical form.
    const fragment = range.cloneContents()
    fragment.querySelectorAll(`${NON_RENDERED_TEXT_SELECTOR}, .document-editor__block-header, .document-editor__preview-note, .document-editor__preserved small, button, input`).forEach(el => el.remove())
    const text = this._normalizeWhitespace(fragment.textContent).trim()

    if (text.length < 1) {
      this.popoverTarget.style.display = "none"
      return
    }

    this.selectedText = text
    this.selectedContext = this.extractContext(range, text, root)
    this.selectedOccurrence = this.computeOccurrence(range, text, root)
    this.selectionInEditor = root !== this.contentTarget
    if (this.selectionInEditor) {
      const startElement = range.startContainer.nodeType === Node.ELEMENT_NODE ? range.startContainer : range.startContainer.parentElement
      const preview = startElement?.closest(".document-editor__block-preview[data-source-from]")
      if (preview?.contains(range.endContainer)) {
        const from = Number.parseInt(preview.dataset.sourceFrom, 10)
        const source = this.element.querySelector(".inline-editor textarea[name=content]")?.value || ""
        const earlier = source.slice(0, from).split(text).length - 1
        this.selectedOccurrence = earlier + this.computeOccurrence(range, text, preview)
        this.selectedContext = this.extractContext(range, text, preview)
      }
    }

    // Position popover near the selection
    const rect = range.getBoundingClientRect()
    const contentRect = this.element.querySelector(".plan-layout__content").getBoundingClientRect()

    this.popoverTarget.style.display = "block"
    this.popoverTarget.style.top = `${rect.bottom - contentRect.top + 8}px`
    this.popoverTarget.style.left = `${rect.left - contentRect.left}px`
  }

  selectionKey(event) {
    if (event.ctrlKey || event.metaKey || event.altKey || event.target.closest("input, textarea, select, [contenteditable]")) return
    if (event.key.toLowerCase() !== "c" || !this.hasPopoverTarget) return

    // Keyboard-created selections do not fire mouseup. Read the live range
    // so C works without the floating action and never uses a stale anchor.
    const selection = window.getSelection()
    if (!selection.rangeCount || selection.isCollapsed ||
        !this.contentTarget.contains(selection.getRangeAt(0).startContainer)) return
    this.checkSelection()
    if (this.popoverTarget.style.display !== "block") return
    event.stopPropagation()
    this.openCommentForm(event)
  }

  commentDraftKey() {
    return JSON.stringify([this.anchorInputTarget.value, this.contextInputTarget.value, this.occurrenceInputTarget.value])
  }

  dismissCommentOutside(event) {
    if (event.button !== 0 || !this.formTarget.matches(":popover-open") || this.formTarget.contains(event.target)) return
    this.commentDrafts ||= new Map()
    this.commentDrafts.set(this.commentDraftKey(), this.formTarget.querySelector("textarea").value)
    this.hideAndResetForm(true)
  }

  async openCommentForm(event) {
    event.preventDefault()
    if (!this.selectedText) return

    if (this.selectionInEditor) {
      const form = this.element.querySelector(".inline-editor form.document-editor")
      const editor = form && window.Stimulus?.getControllerForElementAndIdentifier(form, "coplan--editor")
      if (!editor || !await editor.flush(true)) return
    }

    // Set the anchor text, surrounding context, and occurrence index
    this.anchorInputTarget.value = this.selectedText
    this.contextInputTarget.value = this.selectedContext || ""
    this.occurrenceInputTarget.value = this.selectedOccurrence != null ? this.selectedOccurrence : ""
    this.anchorQuoteTarget.textContent = this.selectedText.length > 120
      ? this.selectedText.substring(0, 120) + "…"
      : this.selectedText
    this.anchorPreviewTarget.style.display = "block"
    this.formTarget.querySelector("textarea").value = this.commentDrafts?.get(this.commentDraftKey()) || ""

    // Move the whole window in viewport coordinates, including the quote.
    const anchor = this.popoverTarget.getBoundingClientRect()
    this.formTarget.classList.toggle("comment-form--sheet", this._isMobile())
    this.formTarget.style.display = "flex"
    this.formTarget.setAttribute("popover", "manual")
    this.formTarget.showPopover()
    if (!this._isMobile()) {
      this.formTarget.style.left = `${Math.max(12, Math.min(anchor.left, innerWidth - this.formTarget.offsetWidth - 12))}px`
      this.formTarget.style.top = `${Math.max(12, Math.min(anchor.bottom + 8, innerHeight - this.formTarget.offsetHeight - 12))}px`
    }
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
        textarea.dispatchEvent(new Event("input", { bubbles: true }))
        textarea.blur()
      }
    }
  }

  hideAndResetForm(preserveDraft = false) {
    if (!preserveDraft) this.commentDrafts?.delete(this.commentDraftKey())
    this.formTarget.dispatchEvent(new CustomEvent("coplan:composer-close", { bubbles: true }))
    if (this.formTarget.hasAttribute("popover")) {
      try { this.formTarget.hidePopover() } catch {}
      this.formTarget.removeAttribute("popover")
    }
    this.formTarget.style.display = "none"
    this.anchorInputTarget.value = ""
    this.contextInputTarget.value = ""
    this.occurrenceInputTarget.value = ""
    this.anchorPreviewTarget.style.display = "none"
    const textarea = this.formTarget.querySelector("textarea")
    if (textarea) textarea.value = ""
    // A create error from the previous attempt shouldn't greet the next one.
    const error = this.formTarget.querySelector("#new-comment-form-error")
    if (error) error.textContent = ""
    this.selectedText = null
    this.selectedContext = null
    this.selectedOccurrence = null
    this.selectionInEditor = false
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
    this.fullText = this._renderedText()
    this._normalizedFullText = this._buildNormalizedMap(this.fullText)

    const highlighted = this.findAndHighlight(anchor, occurrence, "anchor-highlight--active")
    if (highlighted) {
      this._revealDeckSlide(highlighted)
      highlighted.scrollIntoView({ behavior: "smooth", block: "center" })
    }
  }

  openThreadPopover(event) {
    event.stopPropagation()
    this._showThreadPopoverFor(event.currentTarget)
  }

  openEditorThread(event) {
    event.preventDefault()
    event.stopPropagation()
    this._showThreadPopoverFor(event.currentTarget)
  }

  openDetachedThread(event) {
    this._showThreadPopoverFor(event.currentTarget)
  }

  editorPreviewSettled(event) {
    const preview = event.target.closest(".inline-editor .document-editor__block-preview")
    if (preview) this.highlightEditorPreview(preview)
  }

  refreshEditorPreviews() {
    this.element.querySelectorAll(".inline-editor .document-editor__block-preview[data-source-from]")
      .forEach(preview => this.highlightEditorPreview(preview))
  }

  highlightEditorPreview(preview) {
    const from = Number.parseInt(preview.dataset.sourceFrom, 10)
    const to = Number.parseInt(preview.dataset.sourceTo, 10)
    if (!Number.isFinite(from) || !Number.isFinite(to)) return

    preview.querySelectorAll("mark.anchor-highlight").forEach(mark => mark.replaceWith(...mark.childNodes))
    preview.normalize()
    const fullText = this._renderedText(preview)
    const normalized = this._buildNormalizedMap(fullText)
    const source = this.element.querySelector(".inline-editor textarea[name=content]")?.value || ""

    for (const thread of this.threadsTarget.querySelectorAll("[data-anchor-text][data-anchor-start]")) {
      if (thread.dataset.threadOutOfDate === "true") continue
      const start = Number.parseInt(thread.dataset.anchorStart, 10)
      const end = Number.parseInt(thread.dataset.anchorEnd, 10)
      if (!Number.isFinite(start) || !Number.isFinite(end) || start < from || end > to) continue
      const text = thread.dataset.anchorText
      if (!text) continue
      // Most labels are unique inside a block. If a table or diagram repeats
      // one, count exact earlier source matches to pick the corresponding
      // rendered occurrence rather than marking every copy.
      const prefix = source.slice(from, start)
      const count = prefix.split(text).length - 1
      const match = this._findNthNormalized(fullText, text, count, normalized)
      if (!match) continue
      const status = thread.dataset.threadStatus || "open"
      const marks = this.highlightAtIndexAll(match.startIndex, match.matchLength,
        `anchor-highlight anchor-highlight--${status}`, preview)
      marks.forEach(mark => {
        mark.dataset.threadId = thread.id
        mark.dataset.action = "click->coplan--text-selection#openEditorThread"
      })
    }
  }

  // Fired after an async client-side content transform (Mermaid render,
  // syntax highlighting) has rewritten part of the plan body — re-anchor
  // comment highlights against the new DOM.
  handleContentSettled() {
    this.highlightAnchors()
    if (this._pendingThreadId) this._openLinkedThread()
  }

  // Another controller created a thread on the person's behalf (voice
  // dictation) and wants them shown where it landed — same scroll-and-
  // open treatment as arriving via ?thread=ID.
  openThread(event) {
    this._pendingThreadId = event.detail.threadId
    this._pendingThreadOrigin = event.detail.origin
    this._openLinkedThread()
  }

  async copyThreadLink(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    event.preventDefault()
    const link = event.currentTarget
    const feedback = link.querySelector("[data-copy-label]")
    try {
      await navigator.clipboard.writeText(link.href)
      link.dataset.copied = "true"
      link.setAttribute("aria-label", "Link copied")
      feedback.textContent = "Copied"
    } catch {
      link.setAttribute("aria-label", "Could not copy link — try again")
      feedback.textContent = "Couldn’t copy"
      link.dataset.copyFailed = "true"
    }
    clearTimeout(link._copyFeedbackTimer)
    link._copyFeedbackTimer = setTimeout(() => {
      delete link.dataset.copied
      delete link.dataset.copyFailed
      link.setAttribute("aria-label", "Copy link")
      feedback.textContent = "Copy link"
    }, 2000)
  }

  _revealDeckSlide(element) {
    const slide = element.closest(".deck-region .deck-slide")
    if (slide) slide.dispatchEvent(new CustomEvent("coplan:deck-reveal", {
      bubbles: true, detail: { slide: slide.dataset.slide }
    }))
  }

  // Explicit click, keyboard, or deep-link intent opens a persistent discussion.
  // Returns true if the popover was shown, false otherwise.
  _showThreadPopoverFor(trigger) {
    if (!trigger) return false
    this._revealDeckSlide(trigger)
    const threadId = trigger.dataset.threadId
    if (!threadId) return false

    const popover = document.getElementById(`${threadId}_popover`)
    if (!popover) return false

    // If a different popover is already open, close it first. showPopover() throws
    // InvalidStateError if the same popover is already open.
    if (this._activePopover && this._activePopover !== popover) {
      try { this._activePopover.hidePopover() } catch {}
    }

    const wasOpen = this._activePopover === popover
    if (!wasOpen) {
      popover.style.visibility = "hidden"
      try {
        popover.showPopover()
      } catch {
        // Already open — fall through to repositioning.
      }
    }
    this._positionPopoverAtMark(popover, trigger)
    if (!wasOpen) popover.querySelector(".thread-popover__comments").scrollTop = 0
    popover.style.visibility = "visible"

    this._activeMark = trigger
    this._activePopover = popover

    this._attachPopoverToggleListener(popover)
    return true
  }

  _restoreActiveThreadPopover(threadId) {
    if (!threadId || !this._activePopover) return

    const replacementMark = this.contentTarget.querySelector(`.anchor-highlight[data-thread-id="${threadId}"]`)
    if (replacementMark && this._findOpenPopover() === this._activePopover) {
      this._showThreadPopoverFor(replacementMark)
      return
    }

    try { this._activePopover.hidePopover() } catch {}
    this._activeMark = null
    this._activePopover = null
  }

  // Mirror comment_nav_controller#findOpenPopover so we work in browsers where
  // the :popover-open selector throws (older Safari, etc.).
  _findOpenPopover() {
    try {
      return document.querySelector(".thread-popover:popover-open")
    } catch {
      return Array.from(document.querySelectorAll(".thread-popover[popover]"))
        .find(el => el.checkVisibility?.()) || null
    }
  }

  // Bind once per popover element. The toggle listener stays attached for the
  // life of the element so we always learn about native light-dismiss (Esc,
  // click outside, another popover="auto" opening) — not just our own
  // hidePopover() calls.
  _attachPopoverToggleListener(popover) {
    if (popover._coplanToggleBound) return
    popover.addEventListener("toggle", this._boundPopoverToggle)
    popover._coplanToggleBound = true
  }

  // Keep the tracked anchor in sync with native dismissal.
  _handlePopoverToggle(event) {
    if (event.newState !== "closed") return
    if (event.target !== this._activePopover) return
    this._activePopover = null
    this._activeMark = null
  }

  reposition() { this._handleScroll() }

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

  _isMobile() {
    return window.matchMedia("(max-width: 640px)").matches
  }

  _positionPopoverAtMark(popover, mark) {
    if (popover.dataset.positioned === "true") return
    // Small screens: thread popovers become a fixed bottom sheet instead
    // of floating beside the mark (where they'd overflow the viewport).
    if (this._isMobile()) {
      popover.classList.add("thread-popover--sheet")
      popover.style.top = ""
      popover.style.left = ""
      return
    }
    popover.classList.remove("thread-popover--sheet")

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

  extractContext(range, selectedText, root = this.contentTarget) {
    // Grab surrounding text for disambiguation
    const fullText = this._renderedText(root)
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
    const offset = this.getSelectionOffset(range, root)

    const start = Math.max(0, offset - contextBefore)
    const end = Math.min(fullText.length, offset + selectedText.length + contextAfter)
    return fullText.slice(start, end)
  }

  // Computes the 1-based occurrence number of the selected text in the DOM content.
  // This is sent to the server so resolve_anchor_position picks the right match.
  // Uses whitespace-normalized matching for consistency with findAndHighlight.
  computeOccurrence(range, text, root = this.contentTarget) {
    const offset = this.getSelectionOffset(range, root)
    const fullText = this._renderedText(root)
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

  getSelectionOffset(range, root = this.contentTarget) {
    if (!range || !root) return 0

    let offset = 0
    for (const node of this._renderedTextNodes(root)) {
      if (range.startContainer === node) return offset + range.startOffset
      offset += node.textContent.length
    }

    return offset
  }

  // The rendered text model: every text node under the content target except
  // those inside non-rendered elements (see NON_RENDERED_TEXT_SELECTOR).
  // Anchor capture, occurrence counting, and highlighting must all walk this
  // same sequence — mixing it with raw textContent shifts every offset.
  _renderedTextNodes(root = this.contentTarget) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null)
    const nodes = []
    let node

    while ((node = walker.nextNode())) {
      if (!node.parentElement?.closest(NON_RENDERED_TEXT_SELECTOR)) nodes.push(node)
    }

    return nodes
  }

  _renderedText(root = this.contentTarget) {
    let text = ""
    for (const node of this._renderedTextNodes(root)) text += node.textContent
    return text
  }

  highlightAnchors() {
    const activeThreadId = this._activeMark?.dataset.threadId

    // Remove existing anchor highlights before re-highlighting
    this.contentTarget.querySelectorAll("mark.anchor-highlight").forEach(mark => {
      const parent = mark.parentNode
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark)
      parent.removeChild(mark)
    })
    this.contentTarget.normalize()

    // Build the rendered and normalized text once for every thread lookup.
    // Normalizing the entire plan separately for each thread made adding one
    // comment quadratic in the document size and thread count.
    this.fullText = this._renderedText()
    this._normalizedFullText = this._buildNormalizedMap(this.fullText)

    const threads = this.element.querySelectorAll("[data-anchor-text]")
    threads.forEach(thread => {
      if (thread.dataset.anchorKind || thread.dataset.threadOutOfDate === "true") return
      const anchor = thread.dataset.anchorText
      const occurrence = thread.dataset.anchorOccurrence
      const status = thread.dataset.threadStatus || "open"
      const threadId = thread.id

      if (anchor && anchor.length > 0) {
        const isOpen = status === "open"
        const statusClass = isOpen ? "anchor-highlight--open" : "anchor-highlight--resolved"
        const classes = `anchor-highlight ${statusClass}`.trim()
        const marks = this.findAndHighlightAll(anchor, occurrence, classes)

        if (marks.length > 0 && threadId) {
          marks.forEach(mark => {
            if (!mark.dataset.threadId) {
              mark.dataset.threadId = threadId
              mark.style.cursor = "pointer"
              mark.dataset.action = "click->coplan--text-selection#openThreadPopover"
            }
          })
        }
      }
    })

    this._restoreActiveThreadPopover(activeThreadId)
    this.element.dispatchEvent(new CustomEvent("coplan:anchors-updated", { bubbles: true }))
  }

  // Find and highlight the Nth occurrence of text in the rendered DOM.
  // Uses the occurrence index from server-side positional data.
  // Performs whitespace-normalized matching so that anchor text captured
  // from browser selections (which may differ in whitespace from the DOM
  // textContent, e.g. tabs in table selections) can still be located.
  findAndHighlight(text, occurrence, className) {
    const fullText = this.fullText

    let match = null

    if (occurrence !== undefined && occurrence !== "") {
      const occurrenceNum = parseInt(occurrence, 10)
      if (!isNaN(occurrenceNum)) {
        match = this._findNthNormalized(fullText, text, occurrenceNum, this._normalizedFullText)
      }
    } else {
      // Fallback only when occurrence is missing/blank (not when a specific
      // occurrence was requested but couldn't be found — that means the
      // content has changed and highlighting the wrong passage is worse
      // than showing no highlight).
      match = this._findNthNormalized(fullText, text, 0, this._normalizedFullText)
    }

    if (!match) return null

    return this.highlightAtIndex(match.startIndex, match.matchLength, className)
  }

  // Like findAndHighlight but returns all created/reused marks (for multi-cell spans).
  findAndHighlightAll(text, occurrence, className) {
    const fullText = this.fullText

    let match = null

    if (occurrence !== undefined && occurrence !== "") {
      const occurrenceNum = parseInt(occurrence, 10)
      if (!isNaN(occurrenceNum)) {
        match = this._findNthNormalized(fullText, text, occurrenceNum, this._normalizedFullText)
      }
    } else {
      // Fallback only when occurrence is missing/blank
      match = this._findNthNormalized(fullText, text, 0, this._normalizedFullText)
    }

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
  _findNthNormalized(text, search, n, normalizedMap = null) {
    const { normText, origIndices } = normalizedMap || this._buildNormalizedMap(text)
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
    const threadData = document.getElementById(domId)
    if (threadData?.dataset.anchorKind) {
      const event = new CustomEvent("coplan:source-thread", { bubbles: true, cancelable: true, detail: { threadId } })
      this.element.dispatchEvent(event)
      if (event.defaultPrevented) {
        this._pendingThreadId = null
        return
      }
    }
    const activeEditor = document.querySelector('[data-editing="true"] .inline-editor .document-editor__body:not([hidden])')
    const content = activeEditor || this.contentTarget
    const mark = content.querySelector(`mark.anchor-highlight[data-thread-id="${domId}"]`) ||
      this.element.querySelector(`#plan-general-comments [data-thread-id="${domId}"], #plan-detached-comments [data-thread-id="${domId}"]`)
    // Mermaid replaces its source block asynchronously. Wait for the rendered
    // label instead of opening a popover against a source mark that will detach.
    if (mark?.closest('pre[lang="mermaid"]')) {
      if (attempt < 10) {
        setTimeout(() => this._openLinkedThread(attempt + 1), 100)
      }
      return
    }

    if (mark) {
      // A direct link is an explicit request to see this resolved discussion.
      // Reveal its list before scrolling to a button hidden by the default view.
      if (mark.closest(".detached-comments") && threadData?.dataset.threadStatus === "resolved") {
        this.element.classList.remove("plan-layout--hide-resolved")
        this.element.dispatchEvent(new CustomEvent("coplan:resolved-visibility", { bubbles: true }))
      }
      requestAnimationFrame(() => {
        if (this._pendingThreadId !== threadId) return

        const currentMark = content.querySelector(`mark.anchor-highlight[data-thread-id="${domId}"]`) ||
          this.element.querySelector(`#plan-general-comments [data-thread-id="${domId}"], #plan-detached-comments [data-thread-id="${domId}"]`)
        if (currentMark?.isConnected) {
          const generalVoiceComment = this._pendingThreadOrigin === "voice" && currentMark.closest("#plan-general-comments")
          const trigger = generalVoiceComment ? document.querySelector(".voice-btn") || currentMark : currentMark
          if (generalVoiceComment) trigger.dataset.threadId = domId
          else {
            this._revealDeckSlide(currentMark)
            currentMark.scrollIntoView({ behavior: "instant", block: "center" })
          }
          if (this._showThreadPopoverFor(trigger)) {
            this._pendingThreadId = null
            this._pendingThreadOrigin = null
            return
          }
        }

        if (attempt < 10) {
          setTimeout(() => this._openLinkedThread(attempt + 1), 100)
        }
      })
      return
    }

    // Marks may not exist yet (Turbo Drive render timing).
    // Retry a few times; the timer is cleared in disconnect() so a quick
    // navigation away can't fire it against a dead controller.
    if (attempt < 10) {
      this._linkedThreadRetry = setTimeout(() => this._openLinkedThread(attempt + 1), 100)
    }
  }

  highlightAtIndex(startIndex, length, className) {
    const marks = this.highlightAtIndexAll(startIndex, length, className)
    return marks[0] || null
  }

  highlightAtIndexAll(startIndex, length, className, root = this.contentTarget) {
    if (startIndex < 0 || length <= 0) return []

    const textNodes = []
    let offset = 0
    for (const node of this._renderedTextNodes(root)) {
      textNodes.push({ node, start: offset })
      offset += node.textContent.length
    }

    const matchEnd = startIndex + length
    const marks = []

    // Table-structural elements can only contain specific children (e.g.
    // <tr> can only contain <td>/<th>). Wrapping a text node inside one of
    // these with <mark> produces invalid HTML and breaks table layout.
    const TABLE_PARENTS = new Set(["TABLE", "THEAD", "TBODY", "TFOOT", "TR"])

    for (let i = 0; i < textNodes.length; i++) {
      const tn = textNodes[i]
      const nodeEnd = tn.start + tn.node.textContent.length

      if (nodeEnd <= startIndex) continue
      if (tn.start >= matchEnd) break

      // Skip whitespace-only text nodes inside table structure
      if (TABLE_PARENTS.has(tn.node.parentElement?.tagName)) continue

      const localStart = Math.max(0, startIndex - tn.start)
      const localEnd = Math.min(tn.node.textContent.length, matchEnd - tn.start)

      // Skip zero-length ranges (e.g. from text node splits by prior highlights)
      if (localEnd <= localStart) continue

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
