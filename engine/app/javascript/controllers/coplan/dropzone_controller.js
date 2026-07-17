import { Controller } from "@hotwired/stimulus"

// Styled replacement for a native file input, attached to the upload form:
// click the zone (or drag files onto it) and the form submits as soon as
// files are chosen — no separate Upload button.
export default class extends Controller {
  static targets = ["input", "zone", "label"]

  open() {
    this.inputTarget.click()
  }

  dragOver(event) {
    event.preventDefault()
    this.zoneTarget.classList.add("dropzone--active")
  }

  dragLeave() {
    this.zoneTarget.classList.remove("dropzone--active")
  }

  drop(event) {
    event.preventDefault()
    this.zoneTarget.classList.remove("dropzone--active")
    if (!event.dataTransfer?.files?.length) return
    this.inputTarget.files = event.dataTransfer.files
    this.submit()
  }

  changed() {
    if (this.inputTarget.files.length) this.submit()
  }

  submit() {
    const count = this.inputTarget.files.length
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = `Uploading ${count} ${count === 1 ? "file" : "files"}…`
    }
    this.zoneTarget.classList.add("dropzone--busy")
    this.element.requestSubmit()
  }
}
