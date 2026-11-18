import { Controller } from "@hotwired/stimulus"

// Each fresh shell offers a private port. Never send a document to a Window
// by wildcard origin: that browsing context could already have navigated.
export default class extends Controller {
  static targets = ["frame"]
  static values = { url: String, program: Object }

  connect() {
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
    this.port.postMessage(this.programValue)
  }

  disconnect() {
    this.port?.close()
    this.port = null
    this.measured = false
    this.challenge = null
  }
}
