import { Controller } from "@hotwired/stimulus"
import { defaultMarkdownBlockView } from "coplan/markdown_block_state"

// Each navigation opens blocks in the reader's default view,
// <html data-markdown-block-view> from Settings → Appearance, or Rendered.
// markdown.css shows that view before this controller connects, so a
// Source default doesn't flash Rendered. Live replacements carry the
// current view in markdown_block_state, alongside the existing
// deck/viewport state, and mark the blocks they restore with data-view.
export default class extends Controller {
  static targets = ["rendered", "source", "button"]

  connect() {
    const view = this.element.dataset.view || defaultMarkdownBlockView()
    if (view !== this.view) this.apply(view)
    this.element.dataset.view = view
  }

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
    this.element.dataset.view = view
    this.sourceTarget.hidden = !source
    this.renderedTarget.hidden = source
    this.buttonTargets.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.view === view)))
    // Comment highlights live in whichever view shows. Ask the text
    // selection controller to draw them again.
    this.element.dispatchEvent(new CustomEvent("coplan:highlight-settled", { bubbles: true }))
  }
}
