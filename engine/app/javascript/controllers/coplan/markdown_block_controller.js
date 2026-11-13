import { Controller } from "@hotwired/stimulus"

// Each navigation starts rendered. Live replacements carry the current
// view in markdown_block_state, alongside the existing deck/viewport state.
export default class extends Controller {
  static targets = ["rendered", "source", "button"]

  show(event) {
    const view = event.currentTarget.dataset.view
    if (view === this.view) return

    this.apply(view)
  }

  get view() {
    return this.sourceTarget.hidden ? "rendered" : "source"
  }

  apply(view) {
    const source = view === "source"
    this.sourceTarget.hidden = !source
    this.renderedTarget.hidden = source
    this.buttonTargets.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.view === view)))
    // Comment highlights live in whichever view shows. Ask the text
    // selection controller to draw them again.
    this.element.dispatchEvent(new CustomEvent("coplan:highlight-settled", { bubbles: true }))
  }
}
