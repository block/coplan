import { Controller } from "@hotwired/stimulus"

// Opens the sitewide keyboard reference with "?". This listener runs in the
// capture phase so the reference remains reachable while presentation mode
// owns (and stops) the rest of the page's keyboard events.
export default class extends Controller {
  static targets = ["close"]

  connect() {
    this._onKeydown = this._handleKeydown.bind(this)
    document.addEventListener("keydown", this._onKeydown, true)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown, true)
  }

  onToggle(event) {
    if (event.newState === "open") {
      requestAnimationFrame(() => this.closeTarget.focus({ preventScroll: true }))
      return
    }

    if (this._returnFocus?.isConnected) {
      this._returnFocus.focus({ preventScroll: true })
    }
    this._returnFocus = null
  }

  // Keep page-level shortcuts from acting on content hidden behind the
  // reference. Browser defaults (Tab, Escape, button activation) still run.
  contain(event) {
    event.stopPropagation()
  }

  _handleKeydown(event) {
    if (event.key !== "?") return
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (this._isTyping(event.target)) return

    event.preventDefault()
    if (this.element.matches(":popover-open")) return

    this._returnFocus = document.activeElement
    this.element.showPopover()
  }

  _isTyping(target) {
    if (!target) return false
    return target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)
  }
}
