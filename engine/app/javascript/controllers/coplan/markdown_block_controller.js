import { Controller } from "@hotwired/stimulus"

// Switches a Markdown block between its rendered pane and its source
// (MarkdownHelper#render_markdown_blocks). Each page load starts rendered.
// A live update re-renders the document, so the choice made on this page
// is remembered until the next navigation. A block someone switched to
// Source must not snap back while they read.
const choices = new WeakMap()

export default class extends Controller {
  static targets = ["rendered", "source", "button"]

  connect() {
    const view = choices.get(document.body)?.get(this.key)
    if (view && view !== this.view) this.apply(view)
  }

  show(event) {
    const view = event.currentTarget.dataset.view
    if (view === this.view) return

    this.apply(view)
    if (!choices.has(document.body)) choices.set(document.body, new Map())
    choices.get(document.body).set(this.key, view)
  }

  get view() {
    return this.sourceTarget.hidden ? "rendered" : "source"
  }

  // A live update can add or remove blocks above this one, so the key is
  // the block's source plus which copy of that source it is.
  get key() {
    const source = this.sourceTarget.textContent
    const copies = Array.from(document.querySelectorAll("[data-markdown-block]"))
      .filter(block => block.querySelector(":scope > pre[data-markdown-block-source]")?.textContent === source)
    return `${copies.indexOf(this.element)}:${source}`
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
