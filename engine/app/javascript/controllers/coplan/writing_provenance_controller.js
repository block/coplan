import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["trigger", "panel", "details", "highlight", "inspection", "tooltip"]
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

  dismiss() { this.hideTooltip(); if (this.panelTarget.matches(":popover-open")) this.panelTarget.hidePopover() }

  editorReady() { this.finish(); this.editing = true; this.updateAvailability() }
  editorClosed() { this.updateAvailability() }
  readerUpdated() { this.editing = Boolean(document.querySelector('[data-editing="true"]')); this.finish(); this.updateAvailability() }
  updateAvailability() {
    if (!this.hasHighlightTarget) return
    const editing = this.editing || document.querySelector('[data-editing="true"]')
    this.highlightTarget.disabled = Boolean(editing)
    this.highlightTarget.textContent = editing ? "Finish editing to inspect" : "Inspect writing"
  }
  preventEdit(event) { if (this.highlighted) { event.preventDefault(); event.stopImmediatePropagation() } }
  inspectionKey(event) {
    if (!this.highlighted || event.ctrlKey || event.metaKey || event.altKey) return
    const documentAction = event.target.closest("#plan-content-body") && !event.target.closest(".deck-toolbar__step") && ["Enter", " "].includes(event.key)
    if (documentAction || ["c", "e"].includes(event.key.toLowerCase())) { event.preventDefault(); event.stopImmediatePropagation() }
  }
  inspectClick(event) {
    if (!this.highlighted) return
    if (event.target.closest(".deck-toolbar__step")) return
    if (event.target.closest('#plan-content-body, #plan-toolbar a, .site-nav__edit')) {
      event.preventDefault(); event.stopImmediatePropagation()
      this.hover(event)
    }
  }
  finish(event) {
    if (this.highlighted) event?.preventDefault()
    this.clearHighlights()
    if (this.hasHighlightTarget) this.highlightTarget.setAttribute("aria-pressed", "false")
  }
  hideTooltip() { if (this.tooltipTarget.matches(":popover-open")) this.tooltipTarget.hidePopover(); this.hovered = null }

  hover(event) {
    if (!this.highlighted) return
    const root = document.getElementById("plan-content-body")
    if (!root?.contains(event.target)) { this.hideTooltip(); return }
    const caret = document.caretPositionFromPoint?.(event.clientX, event.clientY)
    const fallback = !caret && document.caretRangeFromPoint?.(event.clientX, event.clientY)
    const node = caret?.offsetNode || fallback?.startContainer
    const offset = caret?.offset ?? fallback?.startOffset
    const entry = this.nodeRanges?.get(node)?.find(item => offset >= item.range.startOffset && offset < item.range.endOffset)
    // A caret may snap to the nearest text outside its actual painted bounds.
    const onText = entry && [...entry.range.getClientRects()].some(rect => event.clientX >= rect.left && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom)
    if (!onText) { this.hideTooltip(); return }
    if (this.hovered !== entry) {
      this.hovered = entry
      const source = entry.source || {kind:"unknown"}
      const agent = [...new Set([source.agent_name, source.harness_name].filter(Boolean))].join(" · ") || "AI agent"
      const who = source.kind === "human" ? source.user_name || "Human" : source.kind === "ai" ? agent : "Unknown author"
      const title = document.createElement("strong"); title.textContent = who
      const detail = document.createElement("span")
      const date = source.origin_at && new Date(source.origin_at)
      const minutes = date ? Math.round((date.getTime() - Date.now()) / 60000) : null
      const relative = minutes === null ? null : new Intl.RelativeTimeFormat(undefined,{numeric:"auto"}).format(Math.abs(minutes) < 60 ? minutes : Math.abs(minutes) < 1440 ? Math.round(minutes / 60) : Math.round(minutes / 1440), Math.abs(minutes) < 60 ? "minute" : Math.abs(minutes) < 1440 ? "hour" : "day")
      detail.textContent = [source.origin_revision && `Added in v${source.origin_revision}`, relative].filter(Boolean).join(" · ") || "Origin unrecorded"
      const context = document.createElement("small")
      context.textContent = [source.model, source.kind === "unknown" && source.user_name && `Added by ${source.user_name}`, date && date.toLocaleString(undefined,{dateStyle:"medium",timeStyle:"short"})].filter(Boolean).join(" · ")
      this.tooltipTarget.replaceChildren(title, detail, context)
      this.tooltipTarget.showPopover()
    }
    const width = this.tooltipTarget.offsetWidth, height = this.tooltipTarget.offsetHeight
    this.tooltipTarget.style.left = `${Math.max(8, Math.min(event.clientX + 12, document.documentElement.clientWidth - width - 8))}px`
    this.tooltipTarget.style.top = `${Math.max(8, event.clientY + 18 + height > innerHeight - 80 ? event.clientY - height - 12 : event.clientY + 18)}px`
  }

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
      this.updateAvailability()
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
    if (this.highlighted) { this.finish(); return }
    if (this.editing || document.querySelector('[data-editing="true"]')) { this.updateAvailability(); return }
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
      if (!response.ok || response.redirected || response.status === 202) throw new Error("Sources unavailable. Try again.")
      const data = await response.json()
      if (this.abort.signal.aborted) return
      if (data.revision !== this.revisionValue) throw new Error("Document changed. Reopen writing provenance.")
      if (this.editing || document.querySelector('[data-editing="true"]')) { this.updateAvailability(); return }
      const ranges = this.sourceRanges(root, data.rendered)
      if (!Object.values(ranges).some(list => list.length)) throw new Error("No matching prose or code to highlight.")
      for (const [kind, list] of Object.entries(ranges)) CSS.highlights.set(`coplan-writing-${kind}`, new Highlight(...list))
      this.highlighted = true
      window.getSelection()?.removeAllRanges()
      this.inspectionTarget.hidden = false
      document.body.dataset.writingInspection = "true"
      this.dismiss()
      this.highlightTarget.textContent = "Inspect writing"
      this.highlightTarget.setAttribute("aria-pressed", "true")
    } catch (error) {
      if (error.name !== "AbortError") this.highlightTarget.textContent = error.message
    } finally { if (!this.abort.signal.aborted) this.highlightTarget.disabled = Boolean(this.editing || document.querySelector('[data-editing="true"]')) }
  }

  sourceRanges(root, rendered) {
    const ranges = { human: [], ai: [], unknown: [] }
    this.nodeRanges = new WeakMap()
    let end = 0
    const spans = rendered.runs.map(([length, key]) => { const from = end; end += length; const source = rendered.sources[key]; return { from, to: end, source, kind: source?.kind || "unknown" } })
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    let cursor = 0, node
    while ((node = walker.nextNode())) {
      const parent = node.parentElement
      if (!parent.closest("p, h1, h2, h3, h4, h5, h6, li, td, th, pre") ||
          parent.closest("button, script, style, svg, .deck-toolbar, .deck-notes, .mermaid-container, .mermaid, .code-header, [data-source-badge], [contenteditable]")) continue
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
        const entries = this.nodeRanges.get(node) || []
        entries.push({range, source:span.source})
        this.nodeRanges.set(node, entries)
      }
      cursor = start + text.length
    }
    return ranges
  }

  clearHighlights() {
    if (this.highlighted) for (const kind of ["human", "ai", "unknown"]) CSS.highlights.delete(`coplan-writing-${kind}`)
    this.highlighted = false
    this.nodeRanges = null
    delete document.body.dataset.writingInspection
    if (this.hasInspectionTarget) this.inspectionTarget.hidden = true
    this.hideTooltip()
  }
}
