import { Controller } from "@hotwired/stimulus"
import { captureDeckPositions, restoreDeckPositions } from "coplan/deck_state"

// A disposable reader alongside Raw. The editor remains the sole owner of
// source, selection, undo and saving; preview responses never write back.
export default class extends Controller {
  static targets = ["content", "status", "retry"]
  static values = { url: String }

  connect() {
    this.prefix = `coplan-preview-${crypto.randomUUID()}-`
    this.sequence = 0
  }

  disconnect() { this.cancel() }

  update({ detail: { visible, content } }) {
    const opening = visible && !this.visible
    this.visible = visible
    this.source = content
    if (!visible) { this.cancel(); return }
    if (content === this.renderedSource) {
      this.cancel()
      this.statusTarget.textContent = "Reader preview"
      this.retryTarget.hidden = true
      return
    }
    this.cancel()
    this.statusTarget.textContent = this.html == null ? "Loading preview…" : "Updating preview…"
    this.element.setAttribute("aria-busy", "true")
    this.timer = setTimeout(() => this.render(), opening ? 0 : 300)
  }

  cancel() {
    clearTimeout(this.timer)
    this.sequence++
    this.request?.abort()
    this.element.removeAttribute("aria-busy")
  }

  retry() { if (this.visible) this.render() }
  resume() { if (this.pending && this.visible) this.render() }

  async render() {
    if (!this.visible) return
    if (this.contentTarget.querySelector(".deck--presenting")) { this.pending = true; return }
    this.pending = false
    this.cancel()
    const sequence = this.sequence, source = this.source
    this.request = new AbortController()
    this.element.setAttribute("aria-busy", "true")
    this.retryTarget.hidden = true
    this.statusTarget.textContent = this.html == null ? "Loading preview…" : "Updating preview…"
    try {
      const response = await fetch(this.urlValue, {
        method: "POST", signal: AbortSignal.any([this.request.signal, AbortSignal.timeout(15000)]),
        headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content },
        body: JSON.stringify({ content: source, document: true })
      })
      if (!response.ok || response.redirected) throw new Error("Preview unavailable")
      const html = await response.text()
      if (sequence !== this.sequence || !this.visible) return
      // A presentation may have opened while the request was in flight.
      if (this.contentTarget.querySelector(".deck--presenting")) { this.pending = true; return }
      if (html !== this.html) {
        const positions = captureDeckPositions(this.contentTarget), scroll = this.element.scrollTop
        this.contentTarget.innerHTML = html
        this.isolate()
        restoreDeckPositions(this.contentTarget, positions)
        this.element.scrollTop = scroll
        this.html = html
      }
      this.renderedSource = source
      this.statusTarget.textContent = "Reader preview"
    } catch {
      if (sequence !== this.sequence || !this.visible) return
      this.statusTarget.textContent = this.html == null ? "Preview unavailable. Your source is still editable." : "Could not refresh preview. Showing the last rendered version."
      this.retryTarget.hidden = false
    } finally {
      if (sequence === this.sequence) this.element.removeAttribute("aria-busy")
    }
  }

  isolate() {
    // The hidden reader is still mounted. Keep draft anchors distinct, and
    // detach authored controls from the surrounding editor form.
    const root = this.contentTarget
    const ids = new Map([...root.querySelectorAll("[id]")].map(el => [el.id, this.prefix + el.id]))
    root.querySelectorAll("[id]").forEach(el => { el.id = ids.get(el.id) })
    root.querySelectorAll('a[href^="#"]').forEach(link => {
      try { link.setAttribute("href", `#${encodeURIComponent(this.prefix + decodeURIComponent(link.getAttribute("href").slice(1)))}`) } catch {}
    })
    root.querySelectorAll("[for], [aria-controls], [aria-labelledby], [aria-describedby], [popovertarget]").forEach(el => {
      for (const name of ["for", "aria-controls", "aria-labelledby", "aria-describedby", "popovertarget"]) {
        if (el.hasAttribute(name)) el.setAttribute(name, el.getAttribute(name).split(/\s+/).map(id => ids.get(id) || id).join(" "))
      }
    })
    root.querySelectorAll("input, button, select, textarea, fieldset, output").forEach(el => el.setAttribute("form", this.prefix + "detached"))
  }

  followLink(event) {
    const link = event.target.closest?.('a[href^="#"]')
    if (!link) return
    event.preventDefault()
    event.stopPropagation()
    let id
    try { id = decodeURIComponent(link.getAttribute("href").slice(1)) } catch { return }
    const target = [...this.contentTarget.querySelectorAll("[id]")].find(el => el.id === id)
    if (target) this.element.scrollTop += target.getBoundingClientRect().top - this.element.getBoundingClientRect().top - 12
  }
}
