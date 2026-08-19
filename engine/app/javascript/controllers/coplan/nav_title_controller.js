import { Controller } from "@hotwired/stimulus"

// Fades the plan context (containing-folder control + title) into the sticky top nav
// once the document's own header has scrolled up behind the bar. Persistent wayfinding —
// especially on mobile and on comment deep links, where you land centered
// on an anchor with the masthead already off-screen — that costs zero
// space while the header is still visible.
export default class extends Controller {
  static values = { anchor: { type: String, default: "plan-header" } }

  connect() {
    // #plan-header is stream-replaced on every live plan update, which would
    // strand an observer bound to the old (detached) node. The .plan-masthead
    // wrapper around it is never itself a stream target, so watch that: when
    // it mutates we re-point the IntersectionObserver at the fresh header and
    // re-sync the title copy from it.
    this.masthead = document.querySelector(".plan-masthead")
    this.textEl = this.element.querySelector(".site-nav__doc-title-text")
    this._observeAnchor()

    if (this.masthead) {
      this._mutation = new MutationObserver(() => {
        this._observeAnchor()
        this._syncTitle()
      })
      this._mutation.observe(this.masthead, { childList: true, subtree: true, characterData: true })
    }
  }

  disconnect() {
    this._observer?.disconnect()
    this._mutation?.disconnect()
    this._setVisible(false)
  }

  // Return to the top of the plan. A bare #plan-header jump lands the header
  // under the sticky bar (and reads as "nothing moved"); scroll all the way
  // up instead, so the full masthead is back in view — at which point the
  // observer hides this title on its own.
  scrollToTop(event) {
    event.preventDefault()
    window.scrollTo({ top: 0, behavior: "smooth" })
  }

  // (Re)bind the IntersectionObserver to the current header element. Only
  // rebuilds when the node actually changed, so routine masthead updates
  // (presence, toolbar) don't churn the observer.
  _observeAnchor() {
    const anchor = document.getElementById(this.anchorValue)
    if (!anchor || anchor === this._anchor) return
    this._anchor = anchor

    this._observer?.disconnect()
    this._observer = new IntersectionObserver(
      ([entry]) => this._setVisible(!entry.isIntersecting),
      // Trip the moment the header clears the sticky nav, not the very top
      // of the viewport — otherwise the title would linger under the bar.
      { rootMargin: `-${this._navHeightPx()}px 0px 0px 0px`, threshold: 0 }
    )
    this._observer.observe(anchor)
  }

  // Keep the sticky copy in step with the live header, so a rename that
  // arrives over the wire doesn't leave a stale name pinned to the bar.
  _syncTitle() {
    const title = this.masthead?.querySelector(".page-header__title")?.textContent?.trim()
    if (title && this.textEl && this.textEl.textContent !== title) {
      this.textEl.textContent = title
    }
  }

  _setVisible(visible) {
    this.element.classList.toggle("site-nav__plan-context--visible", visible)
    // Collapsed, it's decorative and must stay out of the tab order; once
    // shown, both the containing-folder and return-to-top links are real controls,
    // so expose them to keyboard and screen-reader users too.
    this.element.setAttribute("aria-hidden", String(!visible))
    this.element.querySelectorAll("a").forEach(link => {
      link.tabIndex = visible ? 0 : -1
    })
  }

  // --nav-height is authored in rem; resolve it to px for rootMargin.
  _navHeightPx() {
    const root = document.documentElement
    const rem = parseFloat(getComputedStyle(root).getPropertyValue("--nav-height")) || 3.5
    return rem * parseFloat(getComputedStyle(root).fontSize)
  }
}
