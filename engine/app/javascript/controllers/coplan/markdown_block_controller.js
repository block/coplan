import { Controller } from "@hotwired/stimulus"

// Switches a Markdown block between its rendered pane and its source
// (MarkdownHelper#render_markdown_blocks). Each page load starts rendered.
// A live update re-renders the document, so the choice made on this page
// is remembered until the next navigation. A block someone switched to
// Source must not snap back while they read, or while an agent edits it.
//
// A block is known by its source plus which copy of that source it is, so
// blocks added or removed above it don't move the choice. An edit inside
// the block changes its source, so a block that isn't known by its source
// falls back to its position, as long as the number of blocks is the same.
const memory = new WeakMap()

const blocks = () => Array.from(document.querySelectorAll("[data-markdown-block]"))

export default class extends Controller {
  static targets = ["rendered", "source", "button"]

  connect() {
    const page = memory.get(document.body)
    if (!page) return

    const view = page.byKey.get(this.key) ||
      (page.count === blocks().length ? page.byPosition.get(this.position) : undefined)
    if (!view) return
    this.remember(page, view)
    if (view !== this.view) this.apply(view)
  }

  show(event) {
    const view = event.currentTarget.dataset.view
    if (view === this.view) return

    this.apply(view)
    if (!memory.has(document.body)) memory.set(document.body, { byKey: new Map(), byPosition: new Map(), count: 0 })
    this.remember(memory.get(document.body), view)
  }

  // Positions only hold while the number of blocks does. When it changes,
  // the blocks known by their source record their new positions as they
  // connect.
  remember(page, view) {
    const count = blocks().length
    if (page.count !== count) {
      page.byPosition.clear()
      page.count = count
    }
    page.byKey.set(this.key, view)
    page.byPosition.set(this.position, view)
  }

  get view() {
    return this.sourceTarget.hidden ? "rendered" : "source"
  }

  get key() {
    const source = this.sourceTarget.textContent
    const copies = blocks()
      .filter(block => block.querySelector(":scope > pre[data-markdown-block-source]")?.textContent === source)
    return `${copies.indexOf(this.element)}:${source}`
  }

  get position() {
    return blocks().indexOf(this.element)
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
