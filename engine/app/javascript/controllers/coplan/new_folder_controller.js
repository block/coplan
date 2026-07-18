import { Controller } from "@hotwired/stimulus"

// Inline "+ New folder" in the sidebar, attached to the <details> element:
// opening the disclosure focuses the name input (Enter submits the form
// natively, Esc closes). Creation is always top-level — nesting happens by
// dragging folders onto folders.
export default class extends Controller {
  static targets = ["input"]

  focus() {
    if (!this.element.open) return
    requestAnimationFrame(() => this.inputTarget.focus())
  }

  close() {
    this.inputTarget.value = ""
    this.element.open = false
  }
}
