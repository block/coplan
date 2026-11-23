import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "button", "error"]

  connect() {
    this.buttonTarget.disabled = false
  }

  async submit(event) {
    event.preventDefault()
    if (this.buttonTarget.disabled) return

    this.buttonTarget.disabled = true
    this.buttonTarget.textContent = "Permanently deleting…"
    this.errorTarget.textContent = ""
    this.element.setAttribute("aria-busy", "true")

    try {
      const response = await fetch(this.formTarget.action, {
        method: "DELETE",
        body: new FormData(this.formTarget),
        headers: {
          "Accept": "application/json"
        }
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error || "Permanent deletion failed. Try again.")

      this.element.innerHTML = result.html
    } catch (error) {
      this.errorTarget.textContent = error.message
      this.buttonTarget.disabled = false
      this.buttonTarget.textContent = "Permanently delete comment"
    } finally {
      this.element.removeAttribute("aria-busy")
    }
  }
}
