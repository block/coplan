import { Controller } from "@hotwired/stimulus"

// Styled replacement for a native file input: a button-styled label wraps the
// visually-hidden input, with a filename readout beside it. `required` can't
// be used on a visually-hidden input (Chrome refuses to submit a form whose
// invalid control isn't focusable), so the submit button stays disabled until
// files are chosen instead.
export default class extends Controller {
  static targets = ["input", "filenames", "submit"]

  connect() {
    this.changed()
  }

  changed() {
    const files = Array.from(this.inputTarget.files || [])
    if (this.hasSubmitTarget) this.submitTarget.disabled = files.length === 0
    if (!this.hasFilenamesTarget) return
    if (files.length === 0) {
      this.filenamesTarget.textContent = "No files selected"
    } else if (files.length === 1) {
      this.filenamesTarget.textContent = files[0].name
    } else {
      this.filenamesTarget.textContent = `${files.length} files selected`
    }
  }
}
