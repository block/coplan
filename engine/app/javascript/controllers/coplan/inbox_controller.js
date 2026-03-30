import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel"]

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
    const isOpen = panel.style.display !== "none"

    if (isOpen) {
      panel.style.display = "none"
    } else {
      // Reload the Turbo Frame for fresh content
      const frame = panel.querySelector("turbo-frame")
      if (frame) frame.reload()
      panel.style.display = ""
    }
  }

  _close(event) {
    if (!this.element.contains(event.target)) {
      this.panelTarget.style.display = "none"
    }
  }
}
