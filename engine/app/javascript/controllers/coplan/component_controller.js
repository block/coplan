import { Controller } from "@hotwired/stimulus"

// Only one embedded view can be under the pointer. Some browsers omit a
// leave event when crossing directly between an opaque frame and the page.
const CAPTURE_TIMEOUT_MS = 3500
let hoveredFrame
function clearPageHover(event) {
  if (!hoveredFrame?.contains(event.target)) setHoveredFrame(null)
}

function setHoveredFrame(frame) {
  if (frame === hoveredFrame) return
  hoveredFrame?.classList.remove("is-frame-hovered")
  hoveredFrame = frame
  if (frame) {
    frame.classList.add("is-frame-hovered")
    document.addEventListener("pointermove", clearPageHover, true)
  } else {
    document.removeEventListener("pointermove", clearPageHover, true)
  }
}

// Each fresh shell offers a private port. Never send a document to a Window
// by wildcard origin: that browsing context could already have navigated.
export default class extends Controller {
  static targets = ["frame", "expand", "selection"]
  static values = { url: String, program: Object }

  connect() {
    this.scheme = matchMedia("(prefers-color-scheme: dark)")
    this.schemeChanged = () => this.syncTheme()
    this.scheme.addEventListener("change", this.schemeChanged)
    this.captureSequence = 0
    this.started = performance.now()
    this.challenge = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16).padStart(8, "0")).join("")
    this.frameTarget.src = this.urlValue + "#" + this.challenge
  }

  ready(event) {
    if (!this.challenge || event.source !== this.frameTarget.contentWindow || event.origin !== "null" ||
        event.data?.component !== this.challenge || event.ports.length !== 1) return
    this.challenge = null
    const program = this.programValue
    this.port = event.ports[0]
    this.port.onmessage = ({data}) => {
      if (data && Object.hasOwn(data, "textSelection") && this.hasSelectionTarget && program.textComments) {
        this.textSelection(data.textSelection, data.startComment === true)
      }
      if (data?.hovered === true) setHoveredFrame(this.element)
      else if (data?.hovered === false && hoveredFrame === this.element) setHoveredFrame(null)
      if (data?.captureId && data.captureId === this.pending?.id) this.pending.resolve(data)
      if (Number.isFinite(data?.height)) {
        this.frameTarget.style.height = Math.min(1200, Math.max(48, data.height)) + "px"
      }
      if (Number.isFinite(data?.renderMs) && !this.measured) {
        this.measured = true
        this.element.dataset.renderMs = Math.round(data.renderMs)
        this.element.dataset.startupMs = Math.round(performance.now() - this.started)
      }
    }
    this.port.postMessage({...program, theme: this.theme()})
  }

  textSelection(region, start) {
    const frame = this.frameTarget
    const button = this.element.querySelector(".document-component__actions button[data-source-target]")
    const active = button && document.activeElement === frame && this.selectionTarget.hidden && !this.gesture
    const valid = active && region && typeof region.quote === "string" && region.quote.length > 0 && region.quote.length <= 4096 &&
      ["x", "y", "w", "h", "width", "height"].every(key => Number.isInteger(region[key]) && region[key] >= 0 && region[key] <= 32768) &&
      region.w > 0 && region.h > 0 && region.x + region.w <= region.width && region.y + region.h <= region.height &&
      Math.abs(region.width - frame.clientWidth) <= 1 && Math.abs(region.height - frame.clientHeight) <= 1
    const selection = valid ? {
      source: frame,
      rect: () => {
        const box = frame.getBoundingClientRect()
        return new DOMRect(box.left + region.x, box.top + region.y, region.w, region.h)
      },
      comment: () => {
        if (this.gesture || !button.isConnected) return
        if (this.resumeAnnotation(button)) return
        const {x, y, w, h, width, height, quote} = region
        const area = {x, y, w, h, width, height, quote}
        this.beginCapture(area, null)
        this.compose(area)
      }
    } : null
    this.dispatch("text-selection", {detail: {source: frame, selection, start}})
  }

  theme() {
    const style = getComputedStyle(this.element)
    const colors = Object.fromEntries(["text", "text-muted", "surface", "surface-muted", "border", "primary"].map(name =>
      [name, style.getPropertyValue("--color-" + name).trim()]))
    return {scheme: style.colorScheme === "dark" ? "dark" : "light", colors}
  }

  syncTheme() {
    if (this.port) this.port.postMessage({theme: this.theme()})
  }

  resumeAnnotation(button) {
    this.commentButton = button
    return !button.dispatchEvent(new CustomEvent("coplan:resume-annotation", {bubbles: true, cancelable: true}))
  }

  annotate(event) {
    if (!this.selectionTarget.hidden) return this.cancel()
    if (this.resumeAnnotation(event.currentTarget)) return
    this.commentButton.setAttribute("aria-pressed", "true")
    this.selectionTarget.hidden = false
    this.selectionTarget.focus({preventScroll: true})
  }

  position(event) {
    const box = this.selectionTarget.getBoundingClientRect()
    const width = Math.max(1, Math.round(box.width)), height = Math.max(1, Math.round(box.height))
    const x = Math.max(0, Math.min(width, Math.round(event.clientX - box.left)))
    const y = Math.max(0, Math.min(height, Math.round(event.clientY - box.top)))
    return {width, height, x, y}
  }

  start(event) {
    if (!event.isPrimary || event.button !== 0 || this.gesture) return
    this.selectionTarget.setPointerCapture(event.pointerId)
    this.beginCapture(this.position(event), event.pointerId)
    this.move(event)
  }

  beginCapture(point, pointerId) {
    const id = ++this.captureSequence
    const snapshot = new Promise(resolve => {
      const finish = value => {
        clearTimeout(timer)
        if (this.pending?.id === id) this.pending = null
        resolve(value)
      }
      const timer = setTimeout(() => finish({}), CAPTURE_TIMEOUT_MS)
      this.pending = {id, resolve: finish}
    })
    this.gesture = {point, pointerId, snapshot}
    this.port?.postMessage({capture: {id, x: point.x, y: point.y}})
  }

  region(end) {
    const {width, height, x, y} = this.gesture.point
    if (Math.abs(x - end.x) + Math.abs(y - end.y) < 5) return {width, height, x, y, w: 0, h: 0}
    return {width, height, x: Math.min(x, end.x), y: Math.min(y, end.y), w: Math.abs(x - end.x), h: Math.abs(y - end.y)}
  }

  move(event) {
    if (event.pointerId !== this.gesture?.pointerId) return
    const {x, y, w, h} = this.region(this.position(event))
    Object.assign(this.selectionTarget.firstElementChild.style, {
      display: "block", left: x + "px", top: y + "px", width: Math.max(3, w) + "px", height: Math.max(3, h) + "px"
    })
  }

  finish(event) {
    if (event.pointerId !== this.gesture?.pointerId) return
    const end = this.position(event)
    if (end.width !== this.gesture.point.width || end.height !== this.gesture.point.height) return this.cancel()
    this.compose(this.region(end))
  }

  key(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this.cancel()
    } else if (["Enter", " "].includes(event.key) && !this.gesture) {
      event.preventDefault()
      const {width, height} = this.position(event)
      this.beginCapture({width, height, x: 0, y: 0}, null)
      this.compose({width, height, x: 0, y: 0, w: width, h: height})
    }
  }

  compose(region) {
    const {snapshot} = this.gesture
    this.gesture = null
    this.hideSelection()
    this.commentButton.dispatchEvent(new CustomEvent("coplan:component-annotation", {
      bubbles: true, detail: {region, capture: this.prepareSnapshot(snapshot, region)}
    }))
  }

  async prepareSnapshot(snapshot, region) {
    // Bound the whole attachment pipeline, including the browser's image decode.
    const attachment = {}
    let timer
    const timeout = new Promise(resolve => { timer = setTimeout(resolve, CAPTURE_TIMEOUT_MS) })
    try {
      const marked = snapshot.then(result => {
        if (typeof result.label === "string") attachment.label = result.label.slice(0, 160)
        return this.markSnapshot(result.png, region)
      })
      attachment.png = await Promise.race([marked, timeout])
      return attachment
    } finally {
      clearTimeout(timer)
    }
  }

  async markSnapshot(blob, region) {
    if (!(blob instanceof Blob) || blob.type !== "image/png" || !blob.size || blob.size > 4 * 1024 * 1024) return
    // The component controls its own pixels. Bound the decode before using
    // them and pass only the parent canvas's PNG onward to the composer.
    try {
      const header = new DataView(await blob.slice(0, 24).arrayBuffer())
      if (header.getUint32(0) !== 0x89504e47 || header.getUint32(4) !== 0x0d0a1a0a ||
          header.getUint32(16) > 1536 || header.getUint32(20) > 1536) return
      const image = await createImageBitmap(blob)
      const canvas = document.createElement("canvas")
      canvas.width = image.width
      canvas.height = image.height
      const context = canvas.getContext("2d")
      context.drawImage(image, 0, 0)
      image.close()
      context.scale(canvas.width / region.width, canvas.height / region.height)
      context.beginPath()
      if (region.w || region.h) context.rect(region.x, region.y, Math.max(1, region.w), Math.max(1, region.h))
      else context.arc(region.x, region.y, 7, 0, 2 * Math.PI)
      for (const [width, color] of [[4, "white"], [2, "#176edf"]]) {
        context.lineWidth = width
        context.strokeStyle = color
        context.stroke()
      }
      return await new Promise(resolve => canvas.toBlob(resolve, "image/png"))
    } catch { return null }
  }

  cancel() {
    if (this.gesture) this.pending?.resolve({})
    this.gesture = null
    this.hideSelection()
  }

  hideSelection() {
    if (!this.hasSelectionTarget || this.selectionTarget.hidden) return
    this.selectionTarget.hidden = true
    this.selectionTarget.firstElementChild.style.display = "none"
    this.commentButton.setAttribute("aria-pressed", "false")
    this.commentButton.focus({preventScroll: true})
  }

  toggleExpanded() {
    this.cancel()
    if (this.element.matches(":popover-open")) return this.collapse()
    this.placeholder = document.createElement("div")
    this.placeholder.style.height = this.element.getBoundingClientRect().height + "px"
    this.placeholder.style.marginBlock = getComputedStyle(this.element).marginBlock
    this.element.before(this.placeholder)
    this.element.popover = "auto"
    this.element.showPopover()
    this.updateExpandControl(true)
  }

  toggled(event) {
    if (event.target === this.element && event.newState === "closed") this.collapse()
  }

  collapse() {
    this.cancel()
    if (!this.placeholder) return
    this.element.dispatchEvent(new CustomEvent("coplan:expander-closing", {bubbles: true}))
    if (this.element.matches(":popover-open")) this.element.hidePopover()
    this.element.removeAttribute("popover")
    this.placeholder.remove()
    this.placeholder = null
    this.updateExpandControl(false)
  }

  updateExpandControl(expanded) {
    const label = expanded ? "Collapse component" : "Expand component"
    this.expandTarget.title = label
    this.expandTarget.setAttribute("aria-label", label)
    this.expandTarget.setAttribute("aria-expanded", String(expanded))
  }

  disconnect() {
    if (hoveredFrame === this.element) setHoveredFrame(null)
    this.collapse()
    this.scheme.removeEventListener("change", this.schemeChanged)
    this.pending?.resolve({})
    this.port?.close()
    this.port = null
    this.measured = false
    this.challenge = null
  }
}
