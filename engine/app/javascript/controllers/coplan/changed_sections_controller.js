import { Controller } from "@hotwired/stimulus"
import { renderedBlocks } from "coplan/content_sections"

// Quiet dots outside authored content, dismissed after a short reading pause.
const TOP_KEY = "__top__"
const READ_DELAY = 3000

export default class extends Controller {
  static targets = ["note", "markerTemplate"]
  static values = { keys: Array, rewritten: Boolean, viewed: Array, updates: Object }

  connect() {
    this.disconnect()
    this.sections = new Map()
    this.visible = new Set()
    this.held = new Map()
    this.timers = new Map()
    const content = this.element.querySelector("#plan-content-body")
    if (!content || !this.hasNoteTarget || this.noteTarget.classList.contains("changed-sections-note--dismissed")) return
    this.element.querySelectorAll(".section-update-marker").forEach(node => node.remove())
    this.element.querySelectorAll(".section-updated").forEach(node => {
      node.classList.remove("section-updated", "section-updated--viewed")
    })
    if (this.rewrittenValue) return

    const keys = new Set(this.keysValue)
    const used = new Set()
    let inIntroduction = true
    for (const node of renderedBlocks(content)) {
      if (/^H[1-3]$/.test(node.tagName)) {
        inIntroduction = false
        const key = this._slug(node.textContent, used)
        if (keys.has(key)) this._mark(node, key)
      } else if (inIntroduction && keys.has(TOP_KEY) && !this.sections.has(TOP_KEY)) {
        this._mark(node, TOP_KEY)
      }
    }
    this.noteTarget.hidden = this.sections.size === 0
    this.observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        const node = entry.target
        if (entry.isIntersecting && entry.intersectionRatio === 1) {
          this.visible.add(node)
          this._schedule(node)
        } else {
          this.visible.delete(node)
          this._cancel(node)
        }
      })
    }, { rootMargin: "-72px 0px -15% 0px", threshold: 1 })
    this.sections.forEach(node => this.observer.observe(node))
  }

  disconnect() {
    this.observer?.disconnect()
    this.timers?.forEach(timer => clearTimeout(timer))
  }

  refresh(event) {
    if (!this.element.querySelector("#plan-content-body")?.contains(event.target)) return
    if (event.detail?.update) {
      const updates = { ...this.updatesValue }
      event.detail.keys.forEach(key => { updates[key] = event.detail.update })
      this.updatesValue = updates
    }
    this.connect()
  }

  visibilityChanged() {
    this.visible.forEach(node => {
      this._cancel(node)
      if (!document.hidden) this._schedule(node)
    })
  }

  hold(event) {
    const node = event.currentTarget.closest(".section-updated")
    const reasons = this.held.get(node) || new Set()
    reasons.add(event.type.startsWith("focus") ? "focus" : "hover")
    this.held.set(node, reasons)
    this._cancel(node)
  }

  release(event) {
    const node = event.currentTarget.closest(".section-updated")
    const reasons = this.held.get(node)
    reasons?.delete(event.type.startsWith("focus") ? "focus" : "hover")
    if (!reasons?.size) this.held.delete(node)
    if (this.visible.has(node)) this._schedule(node)
  }

  dismiss() {
    this.sections.forEach(node => this._view(node))
    this.noteTarget.classList.add("changed-sections-note--dismissed")
    this.noteTarget.inert = true
    this.disconnect()
  }

  _mark(node, key) {
    this.sections.set(key, node)
    node.dataset.updatedSectionKey = key
    node.classList.add("section-updated")
    // Introductions and headings share the same hoverable, focusable dot.
    const marker = this.markerTemplateTarget.content.firstElementChild.cloneNode(true)
    const update = this.updatesValue[key]
    let description = "Updated since your last visit. Open History for details."
    if (update) {
      const when = new Date(update.at).toLocaleString(undefined, {
        month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short"
      })
      description = `Updated by ${update.by}\n${update.ago} · ${when}`
    }
    marker.dataset.tooltip = description
    marker.setAttribute("aria-label", description)
    node.appendChild(marker)
    if (this.viewedValue.includes(key)) this._view(node)
  }

  _schedule(node) {
    if (document.hidden || this.held.has(node) || node.classList.contains("section-updated--viewed") || this.timers.has(node)) return
    this.timers.set(node, setTimeout(() => {
      this.timers.delete(node)
      if (!document.hidden && this.visible.has(node) && !this.held.has(node) && !this.element.closest("[data-editing='true']")) this._view(node)
    }, READ_DELAY))
  }

  _cancel(node) {
    clearTimeout(this.timers.get(node))
    this.timers.delete(node)
  }

  _view(node) {
    this._cancel(node)
    this.viewedValue = [...new Set([...this.viewedValue, node.dataset.updatedSectionKey])]
    node.classList.add("section-updated--viewed")
    const marker = node.querySelector(".section-update-marker")
    if (marker) {
      marker.tabIndex = -1
      marker.setAttribute("aria-hidden", "true")
    }
  }

  _slug(text, used) {
    let base = text.toLowerCase().replace(/\s+/g, "-").replace(/[^a-z0-9-]/g, "")
      .replace(/-{2,}/g, "-").replace(/^-|-$/g, "")
    if (base === "") base = "section"
    let slug = base
    let suffix = 2
    while (used.has(slug)) slug = `${base}-${suffix++}`
    used.add(slug)
    return slug
  }
}
