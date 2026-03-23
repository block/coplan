import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["position", "resolvedToggle"]
  static values = { planId: String }

  connect() {
    this.currentIndex = -1
    this.updatePosition()
    this.handleKeydown = this.handleKeydown.bind(this)
    document.addEventListener("keydown", this.handleKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown)
  }

  handleKeydown(event) {
    // Don't intercept when typing in inputs/textareas
    const tag = event.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || event.target.isContentEditable) return

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
    }
  }

  get openHighlights() {
    return Array.from(document.querySelectorAll("mark.anchor-highlight--open"))
  }

  get allHighlights() {
    return Array.from(document.querySelectorAll("mark.anchor-highlight"))
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

    // Add active class and scroll into view
    mark.classList.add("anchor-highlight--active")
    mark.scrollIntoView({ behavior: "smooth", block: "center" })

    // Open the thread popover if there's one
    const threadId = mark.dataset.threadId
    if (threadId) {
      const popover = document.getElementById(`${threadId}_popover`)
      if (popover) {
        const markRect = mark.getBoundingClientRect()
        popover.showPopover()
        popover.style.top = `${markRect.top}px`
        popover.style.left = `${markRect.right + 12}px`
      }
    }

    this.updatePosition()
  }

  focusReply() {
    let openPopover
    try {
      openPopover = document.querySelector(".thread-popover:popover-open")
    } catch {
      // :popover-open not supported — find the visible popover manually
      openPopover = Array.from(document.querySelectorAll(".thread-popover[popover]"))
        .find(el => el.checkVisibility?.())
    }
    if (!openPopover) return

    const textarea = openPopover.querySelector(".thread-popover__reply textarea")
    if (textarea) {
      textarea.focus({ preventScroll: true })
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
