import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu"]

  toggle() {
    const menu = this.menuTarget
    menu.style.display = menu.style.display === "none" ? "" : "none"
  }

  close(event) {
    if (!this.element.contains(event.target)) {
      this.menuTarget.style.display = "none"
    }
  }

  connect() {
    this._closeHandler = this.close.bind(this)
    document.addEventListener("click", this._closeHandler)
  }

  disconnect() {
    document.removeEventListener("click", this._closeHandler)
  }
}
