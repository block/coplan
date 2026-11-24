import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "error"]
  static values = { saveFailed: String }

  submit() {
    this.element.requestSubmit()
  }

  started() {
    this.errorTarget.textContent = ""
    this.selectTarget.disabled = true
  }

  beforeResponse(event) {
    if (event.detail.fetchResponse.failed) event.preventDefault()
  }

  finished({ detail: { success } }) {
    if (success) return

    this.selectTarget.disabled = false
    this.element.reset()
    this.errorTarget.textContent = this.saveFailedValue
    this.selectTarget.focus()
  }
}
