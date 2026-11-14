import { Controller } from "@hotwired/stimulus"

/*
 * coplan--markdown-block-view
 *
 * Saves the view markdown blocks open in (Settings → Appearance) as soon
 * as it's picked. Plans read the stored choice from
 * <html data-markdown-block-view>, which Turbo keeps across navigations, so
 * a save that lands updates it there and the next plan opens in that view.
 *
 * Like the app theme row, a save that doesn't land puts the stored choice
 * back and says so: in the row, or page-wide once the reader has left
 * Settings. Only the latest pick's outcome touches the page, so quick clicks
 * can't revert a newer choice.
 */
// One save queue for the page, outliving each Settings visit: a reader can
// pick, leave Settings and come back to pick again before the first save
// lands. picked is the latest pick while saves are in flight; once they
// settle, <html> holds the stored choice.
let saving = null
let picked = null
// Compare snapshots only within the same account. Turbo responses can arrive
// after a newer save reply, even when they were rendered before that save.
const storedVersions = new Map()

export default class extends Controller {
  static targets = ["error"]
  static values = { url: String, stored: String, storedAt: String, userId: String }

  connect() {
    // A fresh render carries the server's stored choice, which may have
    // changed in another tab or device since <html> was set. A page Turbo
    // restores from its cache has had it removed (below), so there the
    // stored choice on <html> is current. Remember snapshots even while a
    // pick is saving; sync keeps that optimistic pick selected until it settles.
    if (this.hasStoredValue) this.rememberStored(this.storedValue, this.storedAtValue)
    this.sync()
  }

  beforeCache() {
    this.element.removeAttribute("data-coplan--markdown-block-view-stored-value")
    this.element.removeAttribute("data-coplan--markdown-block-view-stored-at-value")
  }

  rememberStored(view, updatedAt) {
    const previous = storedVersions.get(this.userIdValue)
    if (previous && updatedAt < previous) return
    storedVersions.set(this.userIdValue, updatedAt)
    document.documentElement.dataset.markdownBlockView = view
  }

  sync() {
    this._check(picked || this.stored)
  }

  announce() {
    document.dispatchEvent(new CustomEvent("coplan:markdown-block-view-changed"))
  }

  get stored() {
    return document.documentElement.dataset.markdownBlockView
  }

  // Saves go out one at a time, in pick order, so <html> always holds what
  // the server last stored.
  select(event) {
    const view = picked = event.target.value
    // The session's token at pick time: a save still queued after signing
    // out carries the old session's token, which the server refuses.
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    this._setError("")
    this.announce()

    const save = saving = (saving || Promise.resolve())
      .then(() => this._save(view, csrfToken))
      .then(snapshot => {
        if (snapshot) this.rememberStored(snapshot.view, snapshot.updated_at)
        return Boolean(snapshot)
      })
    save.then(ok => {
      if (save !== saving) return
      saving = picked = null
      this.announce()
      if (ok) return

      // After a Turbo navigation this row is gone, so say it page-wide.
      if (this.element.isConnected) this._setError("Couldn't save that — try again.")
      else this._toast("Couldn't save your Markdown block view — try again.")
    })
  }

  async _save(view, csrfToken) {
    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": csrfToken
        },
        body: `markdown_block_view=${encodeURIComponent(view)}`
      })
      // A signed-out save is redirected to sign-in, which fetch follows to a
      // 200, so a redirect is a refusal too.
      return response.ok && !response.redirected ? await response.json() : false
    } catch {
      // Offline or the request never landed: same outcome as a refusal.
      return false
    }
  }

  _check(view) {
    const radio = view && this.element.querySelector(`input[name='markdown_block_view'][value='${view}']`)
    if (radio) radio.checked = true
  }

  _toast(message) {
    const toasts = document.getElementById("coplan-toasts")
    if (!toasts) return
    const toast = document.createElement("div")
    toast.className = "flash flash--alert toasts__toast"
    toast.dataset.controller = "coplan--toast"
    toast.setAttribute("role", "alert")
    toast.textContent = message
    toasts.append(toast)
  }

  _setError(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.hidden = message === ""
  }
}
