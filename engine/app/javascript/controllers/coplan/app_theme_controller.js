import { Controller } from "@hotwired/stimulus"

/*
 * coplan--app-theme
 *
 * Switches the app theme (Classic, Neutral, …) on <html data-app-theme> as
 * soon as it's picked, then saves it in the background (docs/THEMES.md).
 * "default" follows the site's default, which the defaultValue holds.
 * coplan:theme-changed lets Mermaid redraw with the new palette.
 *
 * Like the push-to-talk row, a save that doesn't land puts the old choice
 * back and says so, so the page never shows a theme the server won't
 * render on the next visit.
 *
 * Settings and the bar's Appearance menu each have one. coplan:app-theme
 * tells the others about a pick, or a failed save putting the old choice
 * back, so their radios agree. The menu has no Default option, so it checks
 * the theme that's showing. It's an event of its own, not
 * coplan:theme-changed plus a look at <html>, because data-app-theme holds
 * only the resolved theme: it can't tell Default from the theme Default
 * resolves to.
 *
 * The stored choice ("default" or a theme key) lives on <html> as
 * data-app-theme-choice, next to data-app-theme. Turbo keeps <html> across
 * navigations and cache restores, so every control reads the same current
 * value, and a save that lands updates it without moving any radio.
 */
// One save queue for the page, shared by every control: Settings and the
// menu are separate controllers, and a pick in one can follow a pick in the
// other before its save lands. picked is the latest pick, saved or not.
let saving = null
let picked = null

export default class extends Controller {
  static targets = ["error"]
  static values = { url: String, default: String }

  connect() {
    this.follow = ({ detail }) => {
      if (detail.source !== this) this._check(detail.choice)
    }
    window.addEventListener("coplan:app-theme", this.follow)

    // A page Turbo restores from its cache can carry an older pick; the
    // latest pick, or else the stored choice on <html>, is current.
    this._check(picked || document.documentElement.dataset.appThemeChoice)
  }

  disconnect() {
    window.removeEventListener("coplan:app-theme", this.follow)
  }

  // Saves go out one at a time, in the order they were picked in any
  // control, so the stored choice on <html> always matches the server. Only
  // the latest pick's outcome touches the page, so quick clicks can't revert
  // a newer choice.
  select(event) {
    const choice = picked = event.target.value
    this._apply(choice)
    this._setError("")
    this._announce(choice)

    const save = saving = (saving || Promise.resolve())
      .then(() => this._save(choice))
      .then(ok => {
        if (ok) document.documentElement.dataset.appThemeChoice = choice
        return ok
      })
    save.then(ok => {
      if (save !== saving) return
      saving = null
      if (ok) return

      const stored = document.documentElement.dataset.appThemeChoice
      if (stored) {
        picked = stored
        this._check(stored)
        this._apply(stored)
        this._announce(stored)
      }
      this._setError("Couldn't save that — try again.")
    })
  }

  async _save(choice) {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": csrfToken
        },
        body: `app_theme=${encodeURIComponent(choice)}`
      })
      return response.ok
    } catch {
      // Offline or the request never landed — same outcome as a refusal.
      return false
    }
  }

  // Checks the radio for a choice, or the theme it shows when this control
  // has no radio for it (the menu has no Default).
  _check(choice) {
    const radios = [...this.element.querySelectorAll("input[type='radio']")]
    const radio = radios.find(r => r.value === choice) || radios.find(r => r.value === this._resolve(choice))
    if (radio) radio.checked = true
  }

  _resolve(choice) {
    return choice === "default" ? this.defaultValue : choice
  }

  _announce(choice) {
    window.dispatchEvent(new CustomEvent("coplan:app-theme", { detail: { choice, source: this } }))
  }

  _apply(choice) {
    const theme = this._resolve(choice)
    if (document.documentElement.dataset.appTheme === theme) return

    document.documentElement.dataset.appTheme = theme
    window.dispatchEvent(new CustomEvent("coplan:theme-changed"))
  }

  _setError(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.hidden = message === ""
  }
}
