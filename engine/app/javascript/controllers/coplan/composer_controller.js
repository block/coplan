import { Controller } from "@hotwired/stimulus"

// The existing outer window is the only movable surface. Nothing is detached,
// duplicated or left behind; its form and anchor remain together in the top layer.
export default class extends Controller {
  connect() {
    this.resizeObserver = new ResizeObserver(() => this.constrain())
    this.resizeObserver.observe(this.element)
  }

  disconnect() { this.resizeObserver.disconnect() }

  startMove(event) { this.startGesture(event, "move") }
  startResize(event) { this.startGesture(event, "resize") }

  startGesture(event, kind) {
    if (event.button !== 0) return
    event.preventDefault()
    this.gesture = { kind, x: event.clientX, y: event.clientY, rect: this.element.getBoundingClientRect() }
    event.currentTarget.setPointerCapture(event.pointerId)
  }

  move(event) {
    if (!this.gesture) return
    const { kind, x, y, rect } = this.gesture
    this.adjust(rect, kind, event.clientX - x, event.clientY - y)
  }

  endGesture() { this.gesture = null }
  moveKey(event) { this.adjustKey(event, "move") }
  resizeKey(event) { this.adjustKey(event, "resize") }

  fitDraft(event) {
    const input = event.target
    if (!input.matches("textarea.composer__input") || !this.element.matches(":popover-open")) return
    const rect = this.element.getBoundingClientRect()
    const previousHeight = input.getBoundingClientRect().height
    const previousScroll = input.scrollTop
    const atEnd = input.selectionEnd === input.value.length
    // Measure the text rather than the flex space allocated to the field.
    input.style.flex = "none"
    input.style.height = "0px"
    const border = input.offsetHeight - input.clientHeight
    const height = Math.min(input.scrollHeight + border, Math.max(70, (window.visualViewport?.height || innerHeight) - 240))
    input.style.height = `${height}px`
    input.style.flex = `1 1 ${height}px`
    if (this.element.dataset.resized && height > previousHeight) {
      this.setRect({ left: rect.left, top: rect.top, width: rect.width, height: rect.height + height - previousHeight })
    }
    this.constrain()
    // Only follow the end while writing there; editing an earlier sentence
    // must not snap the field to the bottom. Never scroll the document.
    input.scrollTop = atEnd ? input.scrollHeight : previousScroll
    if (!atEnd) return
    for (let parent = input.parentElement; parent && parent !== this.element.parentElement; parent = parent.parentElement) {
      if (!/(auto|scroll)/.test(getComputedStyle(parent).overflowY)) continue
      // Reveal the whole writing area, including the send row. Following
      // only the textarea leaves Reply clipped at the scroller's bottom edge.
      const field = input.closest(".composer__writing").getBoundingClientRect()
      const bounds = parent.getBoundingClientRect()
      if (field.bottom > bounds.bottom - 8) parent.scrollTop += field.bottom - bounds.bottom + 8
      else if (field.top < bounds.top && field.height < parent.clientHeight) parent.scrollTop -= bounds.top - field.top
    }
  }

  adjustKey(event, kind) {
    const delta = { ArrowLeft: [-20, 0], ArrowRight: [20, 0], ArrowUp: [0, -20], ArrowDown: [0, 20] }[event.key]
    if (!delta) return
    event.preventDefault()
    event.stopPropagation()
    this.adjust(this.element.getBoundingClientRect(), kind, ...delta)
  }

  adjust(rect, kind, dx, dy) {
    this.element.dataset.positioned = "true"
    this.element.classList.remove("comment-form--sheet", "thread-popover--sheet")
    if (kind === "resize") this.element.dataset.resized = "true"
    this.setRect({ left: rect.left + (kind === "move" ? dx : 0), top: rect.top + (kind === "move" ? dy : 0),
      width: rect.width + (kind === "resize" ? dx : 0), height: rect.height + (kind === "resize" ? dy : 0) }, kind === "resize")
  }

  setRect({ left, top, width, height }, resizing = false) {
    const viewport = window.visualViewport
    const maxWidth = (viewport?.width || innerWidth) - 24
    const maxHeight = (viewport?.height || innerHeight) - 24
    // Resize towards the pointer without moving the opposite corner. Viewport
    // limits take precedence over minimum sizes when little room remains.
    const availableWidth = resizing ? maxWidth + 12 - left : maxWidth
    const availableHeight = resizing ? maxHeight + 12 - top : maxHeight
    width = Math.min(Math.max(resizing ? 280 : 0, width), availableWidth)
    const minHeight = this.element.classList.contains("thread-popover") ? 320 : 260
    height = Math.min(Math.max(resizing ? minHeight : 0, height), availableHeight)
    left = Math.max(12, Math.min(left, maxWidth + 12 - width))
    top = Math.max(12, Math.min(top, maxHeight + 12 - height))
    Object.assign(this.element.style, { left: `${left}px`, top: `${top}px`, width: `${width}px`, right: "auto", bottom: "auto" })
    if (this.element.dataset.resized) this.element.style.height = `${height}px`
  }

  constrain() {
    if (!this.element.matches(":popover-open")) return
    const rect = this.element.getBoundingClientRect()
    if (this.element.dataset.positioned) this.setRect(rect)
    else if (!window.matchMedia("(max-width: 640px)").matches) {
      // Errors and new replies can grow an anchored window after opening.
      // Keep its bottom controls reachable without changing its size.
      const top = Math.max(12, Math.min(rect.top, (window.visualViewport?.height || innerHeight) - rect.height - 12))
      if (Math.abs(top - rect.top) > 1) this.element.style.top = `${top}px`
    }
  }

  toggled(event) {
    if (event.target !== this.element || event.newState !== "closed") return
    this.element.dispatchEvent(new CustomEvent("coplan:composer-close", { bubbles: true }))
  }

  closed(event) {
    if (event.target !== this.element) return
    this.endGesture()
    delete this.element.dataset.positioned
    delete this.element.dataset.resized
    for (const property of ["width", "height", "top", "left", "right", "bottom"]) this.element.style[property] = ""
  }
}
