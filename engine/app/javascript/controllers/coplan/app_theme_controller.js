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
 * tells the others about a pick or a save, so their radios agree. The menu
 * has no Default option, so it checks the theme that's showing.
 */
export default class extends Controller {
  static targets = ["error"]
  // saved: the stored choice, "default" or a theme key. The menu's checked
  // radio can't say which, so the page renders it.
  static values = { url: String, default: String, saved: String }

  connect() {
    this.saved = this.savedValue
    this.follow = ({ detail }) => {
      if (detail.source === this) return
      this._check(detail.choice)
      if (detail.saved) this.saved = detail.choice
    }
    window.addEventListener("coplan:app-theme", this.follow)

    // A page Turbo restores from its cache can carry an older pick; the
    // theme on <html> is current.
    const checked = this.element.querySelector("input[type='radio']:checked")
    const showing = document.documentElement.dataset.appTheme
    if (checked && this._resolve(checked.value) !== showing) this._check(showing)
  }

  disconnect() {
    window.removeEventListener("coplan:app-theme", this.follow)
  }

  // Saves go out one at a time, in the order they were picked, so saved
  // always matches the server. Only the latest pick's outcome touches the
  // page, so quick clicks can't revert a newer choice.
  select(event) {
    const choice = event.target.value
    this._apply(choice)
    this._setError("")
    this._announce(choice, false)

    const save = this.saving = (this.saving || Promise.resolve())
      .then(() => this._save(choice))
      .then(ok => {
        if (ok) {
          this.saved = choice
          this._announce(choice, true)
        }
        return ok
      })
    save.then(ok => {
      if (save !== this.saving) return
      this.saving = null
      if (ok) return

      if (this.saved) {
        this._check(this.saved)
        this._apply(this.saved)
        this._announce(this.saved, false)
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

  _announce(choice, saved) {
    window.dispatchEvent(new CustomEvent("coplan:app-theme", { detail: { choice, saved, source: this } }))
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
