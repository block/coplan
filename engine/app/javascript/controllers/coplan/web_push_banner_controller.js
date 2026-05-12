import { Controller } from "@hotwired/stimulus"
import * as WebPush from "coplan/web_push"

// Encouragement banner. Listens for `coplan:web-push-banner:nudge` events
// (dispatched by the comment form on successful submit) and shows a small
// toast-style banner inviting the user to enable browser notifications.
//
// Eligibility (all must hold):
//   - browser supports Notification + PushManager + we have a VAPID key
//   - permission isn't already "denied"
//   - not already subscribed on this device
//   - the user hasn't dismissed N times (default 3)
//   - the user hasn't already enabled via the banner before
//
// Dismissals and the permanent-off flag live in localStorage so they're
// per-device, which matches how subscriptions work.
const DISMISS_KEY   = "coplan.web_push_banner.dismissals"
const PERMANENT_KEY = "coplan.web_push_banner.permanent_off"

export default class extends Controller {
  static targets = ["title", "hint", "actions"]
  static values = {
    maxDismissals: { type: Number, default: 3 },
    settingsUrl:   { type: String, default: "" }
  }

  connect() {
    this._onNudge = this._onNudge.bind(this)
    document.addEventListener("coplan:web-push-banner:nudge", this._onNudge)
  }

  disconnect() {
    document.removeEventListener("coplan:web-push-banner:nudge", this._onNudge)
  }

  async _onNudge() {
    if (!(await this._eligible())) return
    this.element.hidden = false
  }

  async _eligible() {
    if (localStorage.getItem(PERMANENT_KEY) === "1") return false
    if (!WebPush.isSupported()) return false
    if (WebPush.permission() === "denied") return false
    if (await WebPush.isSubscribed()) return false
    if (this._dismissCount() >= this.maxDismissalsValue) return false
    return true
  }

  async enable() {
    this._setMessage("Enabling…", "")
    try {
      await WebPush.subscribe()
      this._setMessage(
        "All set!",
        "You'll get a desktop notification when someone replies."
      )
      this.actionsTarget.hidden = true
      // Mark permanent so we never nag again on this device — they're already in.
      localStorage.setItem(PERMANENT_KEY, "1")
      setTimeout(() => { this.element.hidden = true }, 4000)
    } catch (err) {
      this._setMessage(
        "Couldn't enable notifications.",
        this._friendlyError(err)
      )
    }
  }

  dismiss() {
    const next = this._dismissCount() + 1
    localStorage.setItem(DISMISS_KEY, String(next))
    if (next >= this.maxDismissalsValue) {
      localStorage.setItem(PERMANENT_KEY, "1")
    }
    this.element.hidden = true
  }

  _dismissCount() {
    const raw = localStorage.getItem(DISMISS_KEY)
    const n = parseInt(raw || "0", 10)
    return Number.isFinite(n) ? n : 0
  }

  _setMessage(title, hint) {
    if (this.hasTitleTarget) this.titleTarget.textContent = title
    if (this.hasHintTarget)  this.hintTarget.textContent  = hint
  }

  _friendlyError(err) {
    const msg = err?.message || String(err)
    if (/permission/i.test(msg)) return "Permission was not granted."
    return msg
  }
}
