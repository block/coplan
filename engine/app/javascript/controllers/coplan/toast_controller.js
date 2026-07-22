import { Controller } from "@hotwired/stimulus"

// A self-dismissing toast. Server-rendered Turbo Stream toasts append into
// #coplan-toasts with this controller attached; it fades the toast out and
// removes it. (Client-built toasts in folder_dnd manage their own timer.)
export default class extends Controller {
  static values = { duration: { type: Number, default: 4000 } }

  connect() {
    this.timer = setTimeout(() => this.element.remove(), this.durationValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
