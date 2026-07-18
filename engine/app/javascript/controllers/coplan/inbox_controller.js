import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "button"]

  connect() {
    this._closeHandler = this._close.bind(this)
    document.addEventListener("click", this._closeHandler)
  }

  disconnect() {
    document.removeEventListener("click", this._closeHandler)
  }

  toggle(event) {
    event.stopPropagation()
    const panel = this.panelTarget
    const isOpen = !panel.hidden

    if (isOpen) {
      this._setOpen(false)
    } else {
      // Reload the Turbo Frame for fresh content
      const frame = panel.querySelector("turbo-frame")
      if (frame) frame.reload()
      this._setOpen(true)
    }
  }

  _close(event) {
    if (!this.element.contains(event.target)) {
      this._setOpen(false)
    }
  }

  _setOpen(open) {
    this.panelTarget.hidden = !open
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", String(open))
  }
}
