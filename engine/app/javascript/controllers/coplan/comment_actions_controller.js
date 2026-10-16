import { Controller } from "@hotwired/stimulus"

// Reveals per-viewer edit and delete actions when this comment
// belongs to the signed-in user. Broadcasts render once for all viewers
// with no current_user, so the server emits the affordance for every
// human or local_agent comment and lets each browser decide whether to show it. The
// server still enforces auth on submit — this is UX, not security.
export default class extends Controller {
  static values = { authorId: String, authorType: String }
  static targets = ["delete", "body", "editor"]

  connect() {
    const me = document.querySelector("meta[name='coplan-current-user-id']")?.content
    this.isMine = ["human", "local_agent"].includes(this.authorTypeValue) &&
                   !!me &&
                   this.authorIdValue === me
    if (this.isMine && this.hasDeleteTarget) {
      this.deleteTarget.hidden = this.hasEditorTarget && !this.editorTarget.hidden
    }
  }

  edit() {
    if (!this.isMine || !this.hasEditorTarget) return
    this.bodyTarget.hidden = true
    this.deleteTarget.hidden = true
    this.editorTarget.hidden = false
    this.editorTarget.querySelector("textarea").focus({ preventScroll: true })
  }

  async save(event) {
    event.preventDefault()
    if (!this.isMine || this.saving) return
    const form = event.target
    if (form.querySelector('[data-dictation-busy="true"]')) return
    this.saving = true
    const button = form.querySelector('[type="submit"]')
    const label = button.innerHTML
    button.disabled = true
    button.textContent = "Saving…"
    const error = form.querySelector(".comment-form__error")
    error.textContent = ""
    try {
      const response = await fetch(form.action, {
        method: "PATCH", body: new FormData(form),
        headers: { "Accept": "text/vnd.turbo-stream.html", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content }
      })
      const html = await response.text()
      if (!response.ok) {
        const stream = new DOMParser().parseFromString(html, "text/html").querySelector("turbo-stream template")
        error.textContent = stream?.content.textContent || "Couldn't save this edit. Please try again."
        return
      }
      window.Turbo.renderStreamMessage(html)
    } catch {
      error.textContent = "Couldn't reach the server. Your edit is still here; try saving again."
    } finally {
      this.saving = false
      button.disabled = false
      button.innerHTML = label
    }
  }

  cancelEdit() {
    this.editorTarget.dispatchEvent(new CustomEvent("coplan:composer-close", { bubbles: true }))
    this.editorTarget.querySelector("form").reset()
    this.editorTarget.hidden = true
    this.bodyTarget.hidden = false
    this.deleteTarget.hidden = false
    this.deleteTarget.querySelector("button").focus({ preventScroll: true })
  }
}
