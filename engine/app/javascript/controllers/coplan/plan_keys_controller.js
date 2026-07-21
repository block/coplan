import { Controller } from "@hotwired/stimulus"

// Keyboard navigation for a plan page:
//
//   Backspace    go back to wherever you navigated from (workspace, search,
//                someone's profile) — falls back to fallbackUrl when the
//                page was opened cold (direct link, new tab)
//   [ / ]        jump between the document and its footnote sections
//                (references, attachments)
//
// Sections register via data-plan-section attributes, in document order.

// Turbo Drive navigates with pushState + fetch, so document.referrer never
// updates after the first real page load — it can't answer "did we get here
// from inside the app?". Track that ourselves: any Turbo visit in this tab
// means there's in-app history worth going back to. (Module scope survives
// Turbo navigations; a full reload resets it, but a full reload also sets a
// real referrer, so the two checks cover each other.)
let visitedInApp = false
document.addEventListener("turbo:visit", () => { visitedInApp = true })

export default class extends Controller {
  static values = { fallbackUrl: String }

  connect() {
    this._onKeydown = this._handleKeydown.bind(this)
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
  }

  _handleKeydown(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    const tag = event.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || event.target.isContentEditable) return
    if (this._popoverOpen()) return

    switch (event.key) {
      case "Backspace":
        // A focused link/button owns its keys (and some screen readers map
        // Backspace); don't hijack.
        if (event.target.closest("a, button, summary")) return
        event.preventDefault()
        this._goBack()
        break
      case "[":
        event.preventDefault()
        this._jump(-1)
        break
      case "]":
        event.preventDefault()
        this._jump(1)
        break
    }
  }

  _goBack() {
    // Came from inside the app (Turbo visit or full-load referrer): real
    // back, preserving the folder you were in, scroll, and history. A cold
    // open (direct link, new tab) has nowhere to go back to — visit the
    // fallback instead.
    const cameFromApp = visitedInApp || document.referrer.startsWith(window.location.origin)
    if (cameFromApp && window.history.length > 1) {
      window.history.back()
    } else if (this.hasFallbackUrlValue && window.Turbo) {
      window.Turbo.visit(this.fallbackUrlValue)
    }
  }

  _jump(delta) {
    const sections = Array.from(this.element.querySelectorAll("[data-plan-section]"))
    if (sections.length === 0) return

    // Current = the last section whose top has scrolled past the upper
    // third of the viewport.
    const threshold = window.innerHeight / 3
    let index = 0
    sections.forEach((section, i) => {
      if (section.getBoundingClientRect().top <= threshold) index = i
    })

    const next = sections[Math.min(sections.length - 1, Math.max(0, index + delta))]
    next.scrollIntoView({ behavior: "smooth", block: "start" })
  }

  _popoverOpen() {
    try {
      return !!document.querySelector(":popover-open")
    } catch {
      return false
    }
  }
}
