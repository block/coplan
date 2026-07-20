import { Controller } from "@hotwired/stimulus"

export default class extends Controller {

  connect() {
    this.currentIndex = -1
    this.activeMark = null
    this.activePopover = null
    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleScroll = this.handleScroll.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
    window.addEventListener("scroll", this.handleScroll, { passive: true })
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    window.removeEventListener("scroll", this.handleScroll)
    this.cancelPendingAdvance()
  }

  handleKeydown(event) {
    // Don't intercept when typing in inputs/textareas or when modifier keys are held
    const tag = event.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || event.target.isContentEditable) return
    if (event.metaKey || event.ctrlKey || event.altKey) return

    switch (event.key) {
      case "j":
      case "ArrowDown":
        event.preventDefault()
        this.next()
        break
      case "k":
      case "ArrowUp":
        event.preventDefault()
        this.prev()
        break
      case "r":
        event.preventDefault()
        this.focusReply()
        break
      case "a":
        event.preventDefault()
        this.acceptCurrent()
        break
      case "d":
        event.preventDefault()
        this.discardCurrent()
        break
      case "s":
        event.preventDefault()
        this.toggleResolved()
        break
    }
  }

  get openHighlights() {
    return this._deduplicateByThread(
      Array.from(document.querySelectorAll("mark.anchor-highlight--open[data-thread-id]"))
    )
  }

  get allHighlights() {
    return this._deduplicateByThread(
      Array.from(document.querySelectorAll("mark.anchor-highlight[data-thread-id]"))
    )
  }

  // Multi-node anchors produce multiple <mark> fragments with the same
  // data-thread-id. Keep only the first mark per thread so j/k navigation
  // treats each thread as a single stop.
  _deduplicateByThread(marks) {
    const seen = new Set()
    return marks.filter(mark => {
      const id = mark.dataset.threadId
      if (seen.has(id)) return false
      seen.add(id)
      return true
    })
  }

  next() {
    const highlights = this.openHighlights
    if (highlights.length === 0) return

    this.currentIndex = (this.currentIndex + 1) % highlights.length
    this.navigateTo(highlights[this.currentIndex])
  }

  prev() {
    const highlights = this.openHighlights
    if (highlights.length === 0) return

    this.currentIndex = this.currentIndex <= 0 ? highlights.length - 1 : this.currentIndex - 1
    this.navigateTo(highlights[this.currentIndex])
  }

  navigateTo(mark) {
    // Remove active highlight from all marks
    document.querySelectorAll(".anchor-highlight--active").forEach(el => {
      el.classList.remove("anchor-highlight--active")
    })

    // Close any currently open popover first — showPopover() throws
    // InvalidStateError if the same popover is already open, and
    // auto-dismiss only works when showing a *different* popover.
    const openPopover = this.findOpenPopover()
    if (openPopover) {
      try { openPopover.hidePopover() } catch {}
    }

    // Add active class and scroll into view
    mark.classList.add("anchor-highlight--active")
    mark.scrollIntoView({ behavior: "instant", block: "center" })

    // Open the thread popover if there's one
    const threadId = mark.dataset.threadId
    if (threadId) {
      const popover = document.getElementById(`${threadId}_popover`)
      if (popover) {
        popover.style.visibility = "hidden"
        popover.showPopover()
        this.positionPopoverAtMark(popover, mark)
        popover.style.visibility = "visible"
        this.activeMark = mark
        this.activePopover = popover
      }
    }
  }

  // Content re-renders (live updates, Mermaid swaps) replace the <mark>
  // nodes: re-attach the open popover to the replacement anchor, or close
  // it if the thread's anchor is gone.
  handleAnchorsUpdated() {
    if (!this.activeMark || !this.activePopover) return

    const threadId = this.activeMark.dataset.threadId
    const replacementMark = this.allHighlights.find(mark => mark.dataset.threadId === threadId)
    if (replacementMark && this.findOpenPopover() === this.activePopover) {
      replacementMark.classList.add("anchor-highlight--active")
      this.activeMark = replacementMark
      this.positionPopoverAtMark(this.activePopover, replacementMark)
      return
    }

    try { this.activePopover.hidePopover() } catch {}
    this.activeMark = null
    this.activePopover = null
  }

  handleScroll() {
    if (!this.activeMark || !this.activePopover) return
    try {
      if (!this.activePopover.matches(":popover-open")) {
        this.activeMark = null
        this.activePopover = null
        return
      }
    } catch { return }
    this.positionPopoverAtMark(this.activePopover, this.activeMark)
  }

  positionPopoverAtMark(popover, mark) {
    // Mirrors text_selection_controller: bottom sheet on small screens.
    if (window.matchMedia("(max-width: 640px)").matches) {
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

  focusReply() {
    const popover = this.findOpenPopover()
    if (!popover) return

    const textarea = popover.querySelector(".thread-popover__reply textarea")
    if (textarea) {
      textarea.focus({ preventScroll: true })
    }
  }

  acceptCurrent() {
    this.submitPopoverAction("accept")
  }

  discardCurrent() {
    this.submitPopoverAction("discard")
  }

  submitPopoverAction(action) {
    const popover = this.findOpenPopover()
    if (!popover) return

    const form = popover.querySelector(`form[data-action-name='${action}']`)
    if (!form) return

    // Normalize currentIndex if popover was opened via mouse (not j/k)
    if (this.currentIndex < 0) {
      this.currentIndex = 0
    }

    // For accept (pending→todo), the thread stays open so we need to
    // explicitly advance. For discard, the thread leaves openHighlights
    // and the current index naturally points to the next one.
    const shouldAdvance = action === "accept"

    // Watch for the broadcast DOM update that replaces the thread data,
    // then advance to the next thread once the highlights have changed.
    // One pending advance at a time, with a timeout so a failed submit
    // (which never mutates the DOM) can't leave an observer behind to
    // fire on some unrelated broadcast later.
    const threadsContainer = document.getElementById("plan-threads")
    if (threadsContainer) {
      this.cancelPendingAdvance()
      this.advanceObserver = new MutationObserver(() => {
        this.cancelPendingAdvance()
        this.advanceAfterAction(shouldAdvance)
      })
      this.advanceObserver.observe(threadsContainer, { childList: true, subtree: true })
      this.advanceTimeout = setTimeout(() => this.cancelPendingAdvance(), 5000)
    }

    form.requestSubmit()
  }

  cancelPendingAdvance() {
    this.advanceObserver?.disconnect()
    this.advanceObserver = null
    clearTimeout(this.advanceTimeout)
    this.advanceTimeout = null
  }

  advanceAfterAction(shouldAdvance) {
    const highlights = this.openHighlights
    if (highlights.length === 0) {
      this.currentIndex = -1
      return
    }
    if (shouldAdvance) {
      this.currentIndex = (this.currentIndex + 1) % highlights.length
    } else if (this.currentIndex >= highlights.length) {
      this.currentIndex = 0
    }
    this.navigateTo(highlights[this.currentIndex])
  }

  findOpenPopover() {
    try {
      return document.querySelector(".thread-popover:popover-open")
    } catch {
      return Array.from(document.querySelectorAll(".thread-popover[popover]"))
        .find(el => el.checkVisibility?.())
    }
  }

  // Keyboard "s": show/hide resolved-thread highlights (the visible
  // toolbar checkbox is gone — this is deliberately a power-user toggle).
  toggleResolved() {
    const planLayout = document.querySelector(".plan-layout")
    if (!planLayout) return

    planLayout.classList.toggle("plan-layout--show-resolved")
  }
}
