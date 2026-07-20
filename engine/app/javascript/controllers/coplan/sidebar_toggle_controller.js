import { Controller } from "@hotwired/stimulus"

// Mobile-only disclosure for the workspace sidebar. Below the breakpoint
// the sections start hidden behind a "Filters & folders" bar; at desktop
// widths CSS hides the button and shows the sections regardless, so this
// controller never fights the layout.
export default class extends Controller {
  static targets = ["button", "sections"]

  connect() {
    this._setOpen(false)
  }

  toggle() {
    this._setOpen(this.sectionsTarget.classList.contains("workspace__sidebar-sections--closed"))
  }

  _setOpen(open) {
    this.sectionsTarget.classList.toggle("workspace__sidebar-sections--closed", !open)
    this.buttonTarget.setAttribute("aria-expanded", String(open))
  }
}
