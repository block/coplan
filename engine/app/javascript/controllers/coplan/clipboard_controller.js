import { Controller } from "@hotwired/stimulus"

// Copies a preset string (data-coplan--clipboard-text-value) to the
// clipboard and gives brief visual feedback on the trigger button.
// Used by the attachments list to copy markdown embed snippets.
export default class extends Controller {
  static values = { text: String }
  static targets = ["button"]

  async copy() {
    try {
      await navigator.clipboard.writeText(this.textValue)
      this.flash("✓ Copied")
    } catch {
      this.flash("Copy failed")
    }
  }

  flash(label) {
    if (!this.hasButtonTarget) return
    const button = this.buttonTarget
    if (button.dataset.originalLabel === undefined) {
      button.dataset.originalLabel = button.textContent
    }
    button.textContent = label
    clearTimeout(this.resetTimer)
    this.resetTimer = setTimeout(() => {
      button.textContent = button.dataset.originalLabel
    }, 1500)
  }

  disconnect() {
    clearTimeout(this.resetTimer)
  }
}
