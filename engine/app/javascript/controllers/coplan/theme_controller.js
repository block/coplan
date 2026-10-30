import { Controller } from "@hotwired/stimulus"

// Switches light/dark mode (data-theme), not the app theme (docs/THEMES.md).
// The "theme" names predate app themes and are kept for hosts. Settings and
// the bar's Appearance menu each have one; both follow <html>, so a pick in
// one shows in the other.
export default class extends Controller {
  static values = { url: String }

  connect() {
    this.reflect = () => {
      const mode = document.documentElement.getAttribute("data-theme") || "system"
      const radio = this.element.querySelector(`input[type='radio'][value='${mode}']`)
      if (radio) radio.checked = true
    }
    window.addEventListener("coplan:theme-changed", this.reflect)
    // A page Turbo restores from its cache can carry an older pick.
    this.reflect()
  }

  disconnect() {
    window.removeEventListener("coplan:theme-changed", this.reflect)
  }

  select(event) {
    const theme = event.target.value
    if (theme === "system") {
      document.documentElement.removeAttribute("data-theme")
    } else {
      document.documentElement.setAttribute("data-theme", theme)
    }

    const meta = document.querySelector('meta[name="color-scheme"]')
    if (meta) {
      meta.content = theme === "system" ? "light dark" : theme
    }
    window.dispatchEvent(new CustomEvent("coplan:theme-changed"))

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": csrfToken
      },
      body: `theme=${theme}`
    })
  }
}
