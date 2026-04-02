import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["position", "resolvedToggle"]
  static values = { planId: String }

  connect() {
    this.currentIndex = -1
    this.activeMark = null
    this.activePopover = null
    this.updatePosition()
    this.handleKeydown = this.handleKeydown.bind(this)
    this.handleScroll = this.handleScroll.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
    window.addEventListener("scroll", this.handleScroll, { passive: true })
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
    window.removeEventListener("scroll", this.handleScroll)
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

    this.updatePosition()
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
    const threadsContainer = document.getElementById("plan-threads")
    if (threadsContainer) {
      const observer = new MutationObserver(() => {
        observer.disconnect()
        this.advanceAfterAction(shouldAdvance)
      })
      observer.observe(threadsContainer, { childList: true, subtree: true })
    }

    form.requestSubmit()
  }

  advanceAfterAction(shouldAdvance) {
    const highlights = this.openHighlights
    if (highlights.length === 0) {
      this.currentIndex = -1
      this.updatePosition()
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

  toggleResolved() {
    const planLayout = document.querySelector(".plan-layout")
    if (!planLayout) return

    if (this.resolvedToggleTarget.checked) {
      planLayout.classList.add("plan-layout--show-resolved")
    } else {
      planLayout.classList.remove("plan-layout--show-resolved")
    }
  }

  updatePosition() {
    if (!this.hasPositionTarget) return

    const highlights = this.openHighlights
    if (highlights.length === 0) {
      this.positionTarget.textContent = ""
      return
    }

    if (this.currentIndex < 0) {
      this.positionTarget.textContent = `${highlights.length} total`
    } else {
      this.positionTarget.textContent = `${this.currentIndex + 1} of ${highlights.length}`
    }
  }
}
