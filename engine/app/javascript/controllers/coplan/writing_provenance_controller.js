import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["trigger", "panel", "details", "highlight"]
  static values = { url: String, revision: Number }

  connect() {
    this.abort = new AbortController()
    this.attempts = 0
    // A native popover can open before a cold-loaded controller connects.
    if (this.panelTarget.matches(":popover-open")) { this.position(); this.load() }
  }
  disconnect() {
    this.abort.abort()
    clearTimeout(this.retryTimer)
    this.clearHighlights()
  }

  toggle(event) {
    if (event.newState !== "open") return
    this.position()
    if (!this.loaded) this.load()
  }

  dismiss() { if (this.panelTarget.matches(":popover-open")) this.panelTarget.hidePopover() }

  position() {
    if (!this.panelTarget.matches(":popover-open")) return
    const rect = this.triggerTarget.getBoundingClientRect()
    const viewportWidth = document.documentElement.clientWidth
    this.panelTarget.style.maxWidth = `${Math.max(0, viewportWidth - 24)}px`
    const width = this.panelTarget.offsetWidth
    this.panelTarget.style.left = `${Math.max(12, Math.min(rect.left, viewportWidth - width - 12))}px`
    this.panelTarget.style.top = `${Math.max(12, Math.min(rect.bottom + 8, innerHeight - this.panelTarget.offsetHeight - 12))}px`
  }

  async load() {
    if (this.loading || this.abort.signal.aborted) return
    this.loading = true
    this.detailsTarget.setAttribute("aria-busy", "true")
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "text/html" }, signal: this.abort.signal })
      if (response.status === 202) {
        this.detailsTarget.textContent = "Calculating writing provenance…"
        if (++this.attempts < 5) this.retryTimer = setTimeout(() => this.load(), 1500)
        else this.showRetry("Still calculating. Try again in a moment.")
        return
      }
      if (!response.ok || response.redirected) throw new Error("Could not load writing provenance.")
      const html = await response.text()
      if (this.abort.signal.aborted) return
      this.detailsTarget.innerHTML = html
      this.loaded = true
      this.position()
    } catch (error) {
      if (error.name !== "AbortError") this.showRetry("Could not load writing provenance.")
    } finally {
      this.loading = false
      if (!this.abort.signal.aborted) this.detailsTarget.removeAttribute("aria-busy")
    }
  }

  showRetry(message) {
    const text = document.createElement("p"); text.textContent = message
    const retry = document.createElement("button"); retry.type = "button"; retry.textContent = "Retry"
    retry.className = "btn btn--ghost btn--sm"; retry.dataset.action = "coplan--writing-provenance#retry"
    this.detailsTarget.replaceChildren(text, retry)
    this.position()
  }
  retry() { this.attempts = 0; this.load() }

  async highlight() {
    if (this.highlighted) {
      this.clearHighlights()
      this.highlightTarget.textContent = "Highlight sources"
      this.highlightTarget.setAttribute("aria-pressed", "false")
      return
    }
    if (!globalThis.Highlight || !globalThis.CSS?.highlights) {
      this.highlightTarget.textContent = "Source highlights unavailable in this browser"
      this.highlightTarget.disabled = true
      return
    }
    const root = document.getElementById("plan-content-body")
    if (!root || root.querySelector("[contenteditable=true]")) {
      this.highlightTarget.textContent = "Close the editor to highlight sources"
      return
    }
    this.highlightTarget.disabled = true
    this.highlightTarget.textContent = "Loading sources…"
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" }, signal: this.abort.signal })
      if (!response.ok || response.status === 202) throw new Error("Sources unavailable. Try again.")
      const data = await response.json()
      if (this.abort.signal.aborted) return
      if (data.revision !== this.revisionValue) throw new Error("Document changed. Reopen writing provenance.")
      const ranges = this.sourceRanges(root, data.rendered)
      if (!Object.values(ranges).some(list => list.length)) throw new Error("No matching prose or code to highlight.")
      for (const [kind, list] of Object.entries(ranges)) CSS.highlights.set(`coplan-writing-${kind}`, new Highlight(...list))
      this.highlighted = true
      this.highlightTarget.textContent = "Hide source highlights"
      this.highlightTarget.setAttribute("aria-pressed", "true")
    } catch (error) {
      if (error.name !== "AbortError") this.highlightTarget.textContent = error.message
    } finally { if (!this.abort.signal.aborted) this.highlightTarget.disabled = false }
  }

  sourceRanges(root, rendered) {
    const ranges = { human: [], ai: [], unknown: [] }
    let end = 0
    const spans = rendered.runs.map(([length, kind]) => { const from = end; end += length; return { from, to: end, kind } })
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    let cursor = 0, node
    while ((node = walker.nextNode())) {
      const parent = node.parentElement
      if (!parent.closest("p, h1, h2, h3, h4, h5, h6, li, td, th, pre") ||
          parent.closest("button, script, style, svg, .deck-region, .mermaid-container, .mermaid, .code-header, [data-source-badge], [contenteditable]")) continue
      const offsets = [], chars = []
      let offset = 0
      for (const char of node.textContent) {
        if (!/\s/u.test(char)) { chars.push(char); for (let i = 0; i < char.length; i++) offsets.push(offset + i) }
        offset += char.length
      }
      const text = chars.join("")
      if (!text) continue
      const start = rendered.text.indexOf(text, cursor)
      if (start < 0) continue
      for (const span of spans) {
        if (!ranges[span.kind] || span.to <= start || span.from >= start + text.length) continue
        const from = Math.max(start, span.from) - start, to = Math.min(start + text.length, span.to) - start
        const range = document.createRange()
        range.setStart(node, offsets[from]); range.setEnd(node, offsets[to - 1] + 1)
        ranges[span.kind].push(range)
      }
      cursor = start + text.length
    }
    return ranges
  }

  clearHighlights() {
    if (this.highlighted) for (const kind of ["human", "ai", "unknown"]) CSS.highlights.delete(`coplan-writing-${kind}`)
    this.highlighted = false
  }
}
