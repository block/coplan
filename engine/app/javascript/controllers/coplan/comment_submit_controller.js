import { Controller } from "@hotwired/stimulus"

// Keep failures in the writing window, with the draft available for retry.
export default class extends Controller {
  static values = { commentsId: String }

  connect() {
    this.button = this.element.querySelector('[type="submit"]')
    this.buttonLabel ||= this.button.innerHTML
    this.error = this.element.querySelector(".comment-form__error")
  }

  started() {
    this.error.textContent = ""
    this.followReply = this.hasCommentsIdValue
  }

  beforeStreamRender(event) {
    const stream = event.target
    if (!this.followReply || stream.getAttribute("action") !== "append" || stream.getAttribute("target") !== this.commentsIdValue) return
    const render = event.detail.render
    event.detail.render = async element => {
      await render(element)
      // Submission and stream rendering finish independently. Follow the reply
      // only once it exists, after the draft has returned to its compact size.
      requestAnimationFrame(() => {
        if (!this.element.isConnected) return
        const comments = this.element.closest(".thread-popover, .source-comments__thread")?.querySelector(".thread-popover__comments")
        if (comments) comments.scrollTop = comments.scrollHeight
      })
      this.followReply = false
    }
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
    this.followReply = false
    this.error.textContent = "Couldn't reach the server. Your draft is still here. Try again when the connection is back."
  }

  finished(event) {
    if (!event.detail.success) this.followReply = false
    if (event.detail.success) {
      this.error.textContent = ""
      this.button.innerHTML = this.buttonLabel
    } else if (this.error.textContent) {
      this.button.textContent = "Try again"
    }
  }
}
