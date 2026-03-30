import { Controller } from "@hotwired/stimulus"

// Observes the inbox-badge element and toggles visibility based on content.
// When Turbo Streams update the badge text (e.g., "3" → "0"), this controller
// automatically adds/removes the hidden class.
export default class extends Controller {
  connect() {
    this._observer = new MutationObserver(() => this.updateVisibility())
    this._observer.observe(this.element, { childList: true, characterData: true, subtree: true })
    this.updateVisibility()
  }

  disconnect() {
    this._observer?.disconnect()
  }

  updateVisibility() {
    const count = parseInt(this.element.textContent.trim(), 10)
    this.element.classList.toggle("inbox-badge--hidden", !count || count === 0)
  }
}
