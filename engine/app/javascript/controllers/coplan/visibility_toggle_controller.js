import { Controller } from "@hotwired/stimulus"

// The plan visibility toggle (author only). Open eye = shared with everyone
// in the org, slashed eye = Private. One click commits — visibility is a
// two-way switch (see PlanPolicy#publish?/#hide?), so there is nothing to
// guard with a dialog: flipping it back is one more click.
//
// The button repaints optimistically, then the server confirms with Turbo
// Streams (a #plan-header re-render carrying the state flag, plus a toast).
// If the request fails, the button reverts to the real state.
export default class extends Controller {
  static values = { hidden: Boolean, publishUrl: String, hideUrl: String }
  static targets = ["label"]

  async toggle() {
    if (this._busy) return
    this._busy = true

    const wasHidden = this.hiddenValue
    this.hiddenValue = !wasHidden
    this._paint()

    try {
      const response = await fetch(wasHidden ? this.publishUrlValue : this.hideUrlValue, {
        method: "PATCH",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Accept": "text/vnd.turbo-stream.html"
        }
      })
      if (!response.ok) throw new Error("Could not change visibility")
      window.Turbo?.renderStreamMessage(await response.text())
    } catch {
      // Put the button back the way the server still has it.
      this.hiddenValue = wasHidden
      this._paint()
    } finally {
      this._busy = false
    }
  }

  _paint() {
    this.element.classList.toggle("visibility-toggle--hidden", this.hiddenValue)
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = this.hiddenValue ? "Private" : "Shared"
    }
    this.element.title = this.hiddenValue ?
      "Private — click to share with everyone in the org" :
      "Shared with everyone — click to make it private (the link keeps working)"
  }
}
