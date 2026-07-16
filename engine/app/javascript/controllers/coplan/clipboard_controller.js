import { Controller } from "@hotwired/stimulus"

// Copies text to the clipboard and gives lightweight "Copied!" feedback on
// the button that triggered it. The text comes from the `text` value when
// present, otherwise from the `source` target's text content — so the same
// controller works for "copy this URL" chips and "copy this snippet" blocks.
//
// Usage:
//   <div data-controller="coplan--clipboard" data-coplan--clipboard-text-value="https://…">
//     <button data-action="coplan--clipboard#copy" data-coplan--clipboard-target="button">Copy</button>
//   </div>
export default class extends Controller {
  static targets = ["source", "button"]
  static values = { text: String }

  async copy() {
    const text = this.hasTextValue && this.textValue !== ""
      ? this.textValue
      : this.sourceTarget.textContent.trim()

    try {
      await navigator.clipboard.writeText(text)
      this.#flash("Copied!")
    } catch {
      // Clipboard API unavailable (e.g., non-secure context). Fall back to
      // selecting the source text so the user can copy manually.
      this.#flash("Press ⌘C to copy")
      if (this.hasSourceTarget) {
        const range = document.createRange()
        range.selectNodeContents(this.sourceTarget)
        const selection = window.getSelection()
        selection.removeAllRanges()
        selection.addRange(range)
      }
    }
  }

  #flash(message) {
    if (!this.hasButtonTarget) return

    const button = this.buttonTarget
    if (!button.dataset.originalLabel) {
      button.dataset.originalLabel = button.textContent
    }
    button.textContent = message
    button.classList.add("copy-button--copied")

    clearTimeout(this.resetTimer)
    this.resetTimer = setTimeout(() => {
      button.textContent = button.dataset.originalLabel
      button.classList.remove("copy-button--copied")
    }, 2000)
  }

  disconnect() {
    clearTimeout(this.resetTimer)
  }
}
