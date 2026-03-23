import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  submitOnEnter(event) {
    if (event.key !== "Enter") return
    if (event.shiftKey || event.isComposing) return

    const form = event.target.closest("form")
    if (!form) return

    event.preventDefault()
    form.requestSubmit()
  }
}
