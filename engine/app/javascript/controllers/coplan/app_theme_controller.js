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
 */
export default class extends Controller {
  static targets = ["error"]
  static values = { url: String, default: String }

  connect() {
    this.saved = this.element.querySelector("input[name='app_theme']:checked")?.value
  }

  // Saves go out one at a time, in the order they were picked, so saved
  // always matches the server. Only the latest pick's outcome touches the
  // page, so quick clicks can't revert a newer choice.
  select(event) {
    const choice = event.target.value
    this._apply(choice)
    this._setError("")

    const save = this.saving = (this.saving || Promise.resolve())
      .then(() => this._save(choice))
      .then(ok => {
        if (ok) this.saved = choice
        return ok
      })
    save.then(ok => {
      if (save !== this.saving) return
      this.saving = null
      if (ok) return

      if (this.saved) {
        const restored = this.element.querySelector(`input[name='app_theme'][value='${this.saved}']`)
        if (restored) restored.checked = true
        this._apply(this.saved)
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

  _apply(choice) {
    const theme = choice === "default" ? this.defaultValue : choice
    if (document.documentElement.dataset.appTheme === theme) return

    document.documentElement.dataset.appTheme = theme
    window.dispatchEvent(new CustomEvent("coplan:theme-changed"))
  }

  _setError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.hidden = message === ""
  }
}
