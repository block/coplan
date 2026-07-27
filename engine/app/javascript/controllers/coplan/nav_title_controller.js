import { Controller } from "@hotwired/stimulus"

// Fades the plan title into the sticky top nav once the document's own
// header has scrolled up behind the bar. Persistent wayfinding —
// especially on mobile and on comment deep links, where you land centered
// on an anchor with the masthead already off-screen — that costs zero
// space while the header is still visible.
export default class extends Controller {
  static values = { anchor: { type: String, default: "plan-header" } }

  connect() {
    const anchor = document.getElementById(this.anchorValue)
    // No header to track (empty doc, unexpected markup) — stay hidden
    // rather than showing a title that never has a home to return to.
    if (!anchor) return

    this._observer = new IntersectionObserver(
      ([entry]) => this._setVisible(!entry.isIntersecting),
      // Trip the moment the header clears the sticky nav, not the very top
      // of the viewport — otherwise the title would linger under the bar.
      { rootMargin: `-${this._navHeightPx()}px 0px 0px 0px`, threshold: 0 }
    )
    this._observer.observe(anchor)
  }

  disconnect() {
    this._observer?.disconnect()
    this._setVisible(false)
  }

  _setVisible(visible) {
    this.element.classList.toggle("site-nav__doc-title--visible", visible)
  }

  // --nav-height is authored in rem; resolve it to px for rootMargin.
  _navHeightPx() {
    const root = document.documentElement
    const rem = parseFloat(getComputedStyle(root).getPropertyValue("--nav-height")) || 3.5
    return rem * parseFloat(getComputedStyle(root).fontSize)
  }
}
