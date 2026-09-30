import { Controller } from "@hotwired/stimulus"
import { openExpander, attachExpandAffordance, mountPanZoom, nearestHeading } from "coplan/expander"

// An image in a plan. Screenshots and mockups are usually scaled down to
// the reading column, so they get the same takeover a diagram does: the
// corner expand control (or a double-click) opens the image full-window,
// fitted to the screen, on the shared pan/zoom canvas. The frame comes
// from MarkdownHelper#wrap_expandable_images.

// Below this, an image is an icon or badge, and offering to expand it is
// noise.
const WORTH_EXPANDING_PX = 64

export default class extends Controller {
  static targets = [ "image" ]

  connect() {
    if (!this.hasImageTarget) return

    // The expanded spreadsheet deep-clones the table, frame and button
    // included. A cloned button has no listener, so drop it; inside an
    // expander the frame stays inert, because opening an image there would
    // close the surface holding it.
    this.element.querySelector(":scope > .image-frame__expand")?.remove()
    if (this.inert) {
      this.element.classList.remove("is-expandable")
      return
    }

    this.affordance = attachExpandAffordance(this.element, {
      label: "Expand image",
      hint: "Expand image",
      className: "image-frame__expand",
      onExpand: () => this.expand()
    })

    if (this.imageTarget.complete) this.measure()
  }

  disconnect() {
    this.expanded?.close()
  }

  get inert() {
    return Boolean(this.element.closest("dialog.expander"))
  }

  measure() {
    if (this.inert) return
    this.element.classList.toggle("is-expandable",
      Math.max(this.imageTarget.naturalWidth, this.imageTarget.naturalHeight) >= WORTH_EXPANDING_PX)
  }

  expandFromDoubleClick(event) {
    if (this.inert || event.target.closest("a, button") || !this.element.classList.contains("is-expandable")) return
    event.preventDefault()
    // An image inside a table cell must not also expand the table.
    event.stopPropagation()
    window.getSelection()?.removeAllRanges()
    this.expand()
  }

  async expand() {
    const image = this.imageTarget
    if (this.expanded) return
    if (!image.naturalWidth) {
      try { await image.decode() } catch { return }
    }
    if (this.expanded || !this.element.isConnected) return

    const expander = openExpander({
      title: image.alt || nearestHeading(this.element) || "Image",
      label: "Expanded image",
      variant: "image",
      container: this.element.closest('[data-controller~="coplan--source-comments"]') || document.body,
      status: true,
      onClose: () => { this.expanded = null }
    })
    this.expanded = expander

    const content = image.cloneNode(false)
    content.removeAttribute("width")
    content.removeAttribute("height")
    content.removeAttribute("data-coplan--image-expand-target")
    content.removeAttribute("data-action")
    // The browser's own image drag would steal the pan gesture.
    content.draggable = false

    const { viewport } = mountPanZoom(expander, content, {
      width: image.naturalWidth,
      height: image.naturalHeight
    })
    expander.dialog.dispatchEvent(new CustomEvent("coplan:expander-opened", { bubbles: true }))
    viewport.focus({ preventScroll: true })
  }
}
