import { Controller } from "@hotwired/stimulus"

// The plan visibility toggle (author only). Open eye = shared with everyone
// in the org, slashed eye = Private. One click commits — visibility is a
// two-way switch (see PlanPolicy#publish?/#hide?), so there is nothing to
// guard with a dialog: flipping it back is one more click.
//
// The button repaints optimistically, then the server confirms with Turbo
// Streams (a #plan-header re-render carrying the state flag, plus a toast).
// The button itself lives outside the broadcast-replaced header (it's
// policy-gated), so it watches header replacements and syncs from the
// header's data-plan-visibility flag — that's how an API publish or another
// tab's toggle updates this button too.
export default class extends Controller {
  static values = { hidden: Boolean, publishUrl: String, hideUrl: String }
  static targets = ["label"]

  connect() {
    this.abortController = new AbortController()
    const header = document.getElementById("plan-header")
    if (header?.parentNode) {
      this.headerObserver = new MutationObserver(() => this._syncFromHeader())
      this.headerObserver.observe(header.parentNode, { childList: true })
    }
  }

  disconnect() {
    this.abortController.abort()
    this.headerObserver?.disconnect()
  }

  async toggle() {
    if (this._busy) return
    this._busy = true

    const wasHidden = this.hiddenValue
    this.hiddenValue = !wasHidden
    this._paint()

    try {
      const response = await fetch(wasHidden ? this.publishUrlValue : this.hideUrlValue, {
        method: "PATCH",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Accept": "text/vnd.turbo-stream.html"
        },
        signal: this.abortController.signal
      })
      if (!response.ok) throw new Error("Could not change visibility")
      const stream = await response.text()
      // Turbo may have navigated away while the request was in flight — a
      // stream aimed at this page's #plan-header must not land on the next
      // page's header.
      if (!this.element.isConnected) return
      window.Turbo?.renderStreamMessage(stream)
    } catch (error) {
      if (error?.name === "AbortError") return
      // A failed response is ambiguous — the server may have committed the
      // flip before the response was lost. Don't assert the old state:
      // reload and let the server say what's true (same reload-then-toast
      // pattern as folder_dnd).
      if (window.Turbo) {
        document.addEventListener("turbo:load",
          () => this._toast("Couldn't confirm the visibility change — showing the current state.", "alert"),
          { once: true })
        window.Turbo.visit(window.location.href, { action: "replace" })
      } else {
        window.location.reload()
      }
    } finally {
      this._busy = false
    }
  }

  // The server's #plan-header re-render (from our own request or any
  // broadcast) is the authority — mirror its state flag onto the button.
  _syncFromHeader() {
    const state = document.getElementById("plan-header")?.dataset.planVisibility
    if (!state) return
    const hidden = state === "draft"
    if (hidden === this.hiddenValue) return
    this.hiddenValue = hidden
    this._paint()
  }

  _paint() {
    this.element.classList.toggle("visibility-toggle--hidden", this.hiddenValue)
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = this.hiddenValue ? "Private" : "Shared"
    }
    this.element.title = this.hiddenValue ?
      "Private — click to share with everyone in the org" :
      "Shared with everyone — click to make it private (the link keeps working)"
  }

  _toast(message, kind) {
    const container = document.getElementById("coplan-toasts")
    if (!container) return
    const toast = document.createElement("div")
    toast.className = `flash flash--${kind} toasts__toast`
    toast.setAttribute("role", "status")
    toast.textContent = message
    toast.setAttribute("data-controller", "coplan--toast")
    container.appendChild(toast)
  }
}
