import { Controller } from "@hotwired/stimulus"

// Pointer capture keeps the gesture local even outside the image. All event
// bindings belong to Stimulus, so mode changes/navigation clean up naturally.
export default class extends Controller {
  static targets = ["image", "handle", "status"]

  disconnect() { this.cancel() }

  focus() { this.handleTarget.focus({ preventScroll: true }) }

  start(event) {
    if (event.button !== 0 || !event.isPrimary || !this.imageTarget.naturalWidth) return
    event.preventDefault()
    const image = this.imageTarget
    this.drag = { pointer: event.pointerId, x: event.clientX, y: event.clientY, aspect: image.naturalWidth / image.naturalHeight, width: image.getBoundingClientRect().width,
      original: image.getAttribute("width"), moved: false }
    this.focus()
    this.handleTarget.setPointerCapture(event.pointerId)
    this.element.classList.add("is-resizing")
  }

  move(event) {
    if (!this.drag || event.pointerId !== this.drag.pointer) return
    const horizontal = event.clientX - this.drag.x, vertical = (event.clientY - this.drag.y) * this.drag.aspect
    const delta = Math.abs(horizontal) >= Math.abs(vertical) ? horizontal : vertical
    if (!this.drag.moved && Math.abs(delta) < 2) return
    this.drag.moved = true
    this.preview(this.drag.width + delta)
  }

  finish(event) {
    if (!this.drag || event.pointerId !== this.drag.pointer) return
    this.move(event)
    const { moved } = this.drag, width = this.width
    this.clear()
    if (moved) this.element.coplanCommitWidth?.(width)
  }

  cancel() {
    if (this.drag) {
      const original = this.drag.original
      if (original === null) this.imageTarget.removeAttribute("width")
      else this.imageTarget.setAttribute("width", original)
    }
    this.clear()
  }

  clear() {
    const pointer = this.drag?.pointer
    this.drag = null
    if (pointer != null && this.handleTarget.hasPointerCapture(pointer)) this.handleTarget.releasePointerCapture(pointer)
    this.element.classList.remove("is-resizing", "is-snapped")
    this.statusTarget.textContent = ""
  }

  limits() {
    // A leading image's link can itself float and hug the current width.
    // Resize against the paragraph, so linked pictures can still grow.
    let parent = this.element.closest("p") || this.element.parentElement
    while (!parent.clientWidth && parent.parentElement) parent = parent.parentElement
    const style = getComputedStyle(parent)
    const available = parent.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)
    const full = Math.min(available, this.imageTarget.naturalWidth)
    return { full, min: Math.min(64, full) }
  }

  preview(requested, snapping = true) {
    const { full, min } = this.limits()
    const snap = snapping ? Math.min(24, full * 0.03) : 0
    this.width = requested >= full - snap ? null : Math.round(Math.max(min, Math.min(full, requested)))
    if (this.width === null) this.imageTarget.removeAttribute("width")
    else this.imageTarget.setAttribute("width", this.width)
    this.element.classList.toggle("is-snapped", this.width === null)
    this.showSize()
  }

  showSize() { this.statusTarget.textContent = this.width === null ? "100%" : `${this.width} px` }

  keydown(event) {
    if (event.key === "Escape" && this.drag) { event.preventDefault(); this.cancel(); return }
    if (this.drag || !["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"].includes(event.key)) return
    event.preventDefault()
    event.stopPropagation()
    if (!this.imageTarget.naturalWidth) return
    const { full, min } = this.limits()
    const direction = ["ArrowLeft", "ArrowUp"].includes(event.key) ? -1 : 1
    this.preview(event.key === "End" ? full : event.key === "Home" ? min : this.imageTarget.getBoundingClientRect().width + direction * (event.shiftKey ? 1 : 10), false)
    this.element.coplanCommitWidth?.(this.width)
    this.showSize()
    this.element.classList.remove("is-snapped")
  }
}
