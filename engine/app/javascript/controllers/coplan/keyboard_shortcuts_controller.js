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
    // The opening key is captured before page listeners can cancel a hold.
    this.dispatch("open")
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
