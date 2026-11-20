import { Controller } from "@hotwired/stimulus"

// Each fresh shell offers a private port. Never send a document to a Window
// by wildcard origin: that browsing context could already have navigated.
export default class extends Controller {
  static targets = ["frame", "expand"]
  static values = { url: String, program: Object }

  connect() {
    this.scheme = matchMedia("(prefers-color-scheme: dark)")
    this.schemeChanged = () => this.syncTheme()
    this.scheme.addEventListener("change", this.schemeChanged)
    this.started = performance.now()
    this.challenge = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16).padStart(8, "0")).join("")
    this.frameTarget.src = this.urlValue + "#" + this.challenge
  }

  ready(event) {
    if (!this.challenge || event.source !== this.frameTarget.contentWindow || event.origin !== "null" ||
        event.data?.component !== this.challenge || event.ports.length !== 1) return
    this.challenge = null
    this.port = event.ports[0]
    this.port.onmessage = ({data}) => {
      if (Number.isFinite(data?.height)) {
        this.frameTarget.style.height = Math.min(1200, Math.max(48, data.height)) + "px"
      }
      if (Number.isFinite(data?.renderMs) && !this.measured) {
        this.measured = true
        this.element.dataset.renderMs = Math.round(data.renderMs)
        this.element.dataset.startupMs = Math.round(performance.now() - this.started)
      }
    }
    this.port.postMessage({...this.programValue, theme: this.theme()})
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

  toggleExpanded() {
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
    if (!this.placeholder) return
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
    this.collapse()
    this.scheme.removeEventListener("change", this.schemeChanged)
    this.port?.close()
    this.port = null
    this.measured = false
    this.challenge = null
  }
}
