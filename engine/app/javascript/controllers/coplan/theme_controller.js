import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

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
