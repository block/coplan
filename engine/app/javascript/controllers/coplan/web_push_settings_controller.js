import { t } from "coplan/ui_messages"
import { Controller } from "@hotwired/stimulus"
import * as WebPush from "coplan/web_push"

// Drives the Notifications card on the Settings page. Reflects the current
// browser's subscription and its server registration for the current account.
export default class extends Controller {
  static targets = ["enableButton", "disableButton", "status"]
  static values  = { devicesUrl: { type: String, default: "" } }

  async connect() {
    this._setStatus(t("coplan.client.settings.checking_notifications"))
    await this._refresh()
  }

  async enable() {
    this._setStatus(t("coplan.client.settings.requesting_notification_permission"))
    try {
      await WebPush.subscribe()
      this._setStatus(t("coplan.client.settings.notifications_enabled"))
      this._reloadDevices()
    } catch (err) {
      this._setStatus(this._friendlyError(err))
    }
    await this._refresh()
  }

  async disable() {
    this._setStatus(t("coplan.client.settings.disabling_notifications"))
    try {
      await WebPush.unsubscribe()
      this._setStatus(t("coplan.client.settings.notifications_disabled"))
      this._reloadDevices()
    } catch (err) {
      this._setStatus(this._friendlyError(err))
    }
    await this._refresh()
  }

  // Tell the device-list turbo-frame to refetch itself so the row for this
  // browser appears (or disappears) without a full page reload.
  _reloadDevices() {
    if (!this.devicesUrlValue) return
    const frame = document.getElementById("web-push-devices")
    if (!frame) return
    // Setting src triggers a fetch even when the URL hasn't changed.
    frame.src = this.devicesUrlValue
  }

  // ---- internals ----

  async _refresh() {
    if (!WebPush.isSupported()) {
      this._setStatus(t("coplan.client.settings.notifications_unsupported"))
      this._show(this.enableButtonTarget, false)
      this._show(this.disableButtonTarget, false)
      return
    }

    const perm = WebPush.permission()
    if (perm === "denied") {
      this._setStatus(t("coplan.client.settings.notifications_blocked"))
      this._show(this.enableButtonTarget, false)
      this._show(this.disableButtonTarget, false)
      return
    }

    let subscribed
    try {
      subscribed = await WebPush.isSubscribed()
    } catch {
      this._setStatus(t("coplan.client.settings.check_notifications_failed"))
      this._show(this.enableButtonTarget, true)
      this._show(this.disableButtonTarget, false)
      return
    }
    this._show(this.enableButtonTarget, !subscribed)
    this._show(this.disableButtonTarget, subscribed)
    if (!this.statusTarget.textContent || this.statusTarget.textContent === t("coplan.client.settings.checking_notifications")) {
      this._setStatus(subscribed ? t("coplan.client.settings.notifications_active") : t("coplan.client.settings.notifications_inactive"))
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
    if (/permission/i.test(msg)) return t("coplan.client.settings.notification_permission_denied")
    return t("coplan.client.settings.update_notifications_failed")
  }
}
