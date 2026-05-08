import { Controller } from "@hotwired/stimulus"
import * as WebPush from "coplan/web_push"

// Drives the Notifications card on the Settings page. Reflects the current
// browser's subscription state (which the server can't know — it's per-device).
export default class extends Controller {
  static targets = ["enableButton", "disableButton", "status"]

  async connect() {
    await this._refresh()
  }

  async enable() {
    this._setStatus("Requesting permission…")
    try {
      await WebPush.subscribe()
      this._setStatus("Notifications enabled on this device.")
    } catch (err) {
      this._setStatus(this._friendlyError(err))
    }
    await this._refresh()
  }

  async disable() {
    this._setStatus("Disabling…")
    try {
      await WebPush.unsubscribe()
      this._setStatus("Notifications disabled on this device.")
    } catch (err) {
      this._setStatus(this._friendlyError(err))
    }
    await this._refresh()
  }

  // ---- internals ----

  async _refresh() {
    if (!WebPush.isSupported()) {
      this._setStatus("This browser doesn't support web push notifications.")
      this._show(this.enableButtonTarget, false)
      this._show(this.disableButtonTarget, false)
      return
    }

    const perm = WebPush.permission()
    if (perm === "denied") {
      this._setStatus("Notifications are blocked. Allow them in your browser settings to enable.")
      this._show(this.enableButtonTarget, false)
      this._show(this.disableButtonTarget, false)
      return
    }

    const subscribed = await WebPush.isSubscribed()
    this._show(this.enableButtonTarget, !subscribed)
    this._show(this.disableButtonTarget, subscribed)
    if (!this.statusTarget.textContent) {
      this._setStatus(subscribed ? "Enabled on this device." : "")
    }
  }

  _show(el, visible) {
    if (!el) return
    el.hidden = !visible
  }

  _setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }

  _friendlyError(err) {
    const msg = err?.message || String(err)
    if (/permission/i.test(msg)) return "Permission was not granted."
    return msg
  }
}
