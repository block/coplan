import { Controller } from "@hotwired/stimulus"

// Keep failures in the writing window, with the draft available for retry.
export default class extends Controller {
  connect() {
    this.button = this.element.querySelector('[type="submit"]')
    this.buttonLabel ||= this.button.innerHTML
    this.error = this.element.querySelector(".comment-form__error")
  }

  started() {
    this.error.textContent = ""
  }

  response(event) {
    const response = event.detail.fetchResponse
    if (response.succeeded) return
    this.error.textContent = "Couldn't post your comment. Your draft is still here. Try again."
    // Validation streams can provide a more specific message. HTML error
    // pages must not replace the document and take the draft with them.
    if (!response.contentType?.includes("text/vnd.turbo-stream.html")) event.preventDefault()
  }

  failed() {
    this.error.textContent = "Couldn't reach the server. Your draft is still here. Try again when the connection is back."
  }

  finished(event) {
    if (event.detail.success) {
      this.error.textContent = ""
      this.button.innerHTML = this.buttonLabel
    } else if (this.error.textContent) {
      this.button.textContent = "Try again"
    }
  }
}
