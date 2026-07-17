import { Controller } from "@hotwired/stimulus"

// Drag-and-drop upload zone wrapping a visually-hidden file input. Files
// upload immediately on selection or drop — there is no separate submit
// button — so the controller sits on the <form> and posts via
// requestSubmit(), letting Turbo handle the redirect.
export default class extends Controller {
  static targets = ["input", "text"]

  dragOver(event) {
    event.preventDefault()
    this.element.classList.add("attachments-dropzone--active")
  }

  dragLeave(event) {
    event.preventDefault()
    this.element.classList.remove("attachments-dropzone--active")
  }

  drop(event) {
    event.preventDefault()
    this.element.classList.remove("attachments-dropzone--active")
    if (!event.dataTransfer?.files?.length) return
    this.inputTarget.files = event.dataTransfer.files
    this.changed()
  }

  changed() {
    const files = this.inputTarget.files
    if (!files.length) return
    if (this.hasTextTarget) {
      this.textTarget.textContent =
        files.length === 1 ? `Uploading ${files[0].name}…` : `Uploading ${files.length} files…`
    }
    this.element.classList.add("attachments-dropzone--uploading")
    this.element.requestSubmit()
  }
}
