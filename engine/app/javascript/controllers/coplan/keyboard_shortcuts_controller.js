import { Controller } from "@hotwired/stimulus"
import { registerShortcuts } from "coplan/shortcuts"

export default class extends Controller {
  connect() {
    this.releaseShortcuts = registerShortcuts(this, "help", event => this.open(event))
  }

  disconnect() { this.releaseShortcuts() }

  open(event) {
    event.preventDefault()
    if (this.element.open || event.repeat) return
    this.element.showModal()
  }

  close() { this.element.close() }

  backdrop(event) {
    if (event.target === this.element) this.close()
  }

  // Focus trapping and restoration are native; keep widget/voice listeners
  // from seeing keys belonging to the dialog.
  contain(event) { event.stopPropagation() }
}
