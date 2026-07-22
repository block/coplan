import { Controller } from "@hotwired/stimulus"

// Mounts the save bookmark into the plan header's title row. The bookmark
// is viewer-relative (saved state, move URL) so it can't be rendered inside
// the broadcast-replaced #plan-header partial — instead the show view
// renders it into a <template> and this controller stamps a fresh copy into
// #plan-bookmark-slot on load and again after every broadcast replaces the
// header.
export default class extends Controller {
  static targets = ["template"]

  connect() {
    this.observer = new MutationObserver(() => this.#mount())
    this.observer.observe(this.element, { childList: true, subtree: true })
    this.#mount()
  }

  disconnect() {
    this.observer.disconnect()
  }

  #mount() {
    if (!this.hasTemplateTarget) return
    const slot = this.element.querySelector("#plan-bookmark-slot")
    // Stamping into the slot re-fires the observer; the childElementCount
    // check makes that re-entry a no-op instead of a loop.
    if (!slot || slot.childElementCount > 0) return
    slot.append(this.templateTarget.content.cloneNode(true))
  }
}
