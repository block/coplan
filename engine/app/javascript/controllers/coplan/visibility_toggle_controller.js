import { Controller } from "@hotwired/stimulus"

// The header visibility eye (author only). Open eye = shared with everyone,
// slashed eye = Private. Two clicks, no dialog, no reload:
//
//   click 1  previews the flip (the slash toggles, the button pulses) —
//            it reverts by itself if you wander off
//   click 2  commits via fetch; the broadcast header refresh carries the
//            Private flag, so nothing else needs repainting
export default class extends Controller {
  static values = { hidden: Boolean, publishUrl: String, hideUrl: String }

  disconnect() {
    clearTimeout(this._revertTimer)
  }

  click() {
    if (this._armed) {
      this._commit()
    } else {
      this._arm()
    }
  }

  _arm() {
    this._armed = true
    this.element.classList.add("visibility-toggle--armed")
    this.element.classList.toggle("visibility-toggle--hidden", !this.hiddenValue)
    this.element.title = this.hiddenValue ?
      "Click again to share with everyone in the org" :
      "Click again to make this private — hidden from lists and search (the link keeps working)"
    // Unconfirmed after a pause: put the eye back the way it was.
    this._revertTimer = setTimeout(() => this._reset(), 4000)
  }

  async _commit() {
    clearTimeout(this._revertTimer)
    const url = this.hiddenValue ? this.publishUrlValue : this.hideUrlValue
    try {
      const response = await fetch(url, {
        method: "PATCH",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Accept": "application/json"
        }
      })
      if (!response.ok) throw new Error("Could not change visibility")
      const data = await response.json()
      this.hiddenValue = data.visibility === "draft"
    } catch {
      // Leave the real state untouched; the reset below repaints it.
    }
    this._reset()
  }

  _reset() {
    this._armed = false
    clearTimeout(this._revertTimer)
    this.element.classList.remove("visibility-toggle--armed")
    this.element.classList.toggle("visibility-toggle--hidden", this.hiddenValue)
    this.element.title = this.hiddenValue ?
      "Private — click to share with everyone" :
      "Shared with everyone — click to make it private"
  }
}
