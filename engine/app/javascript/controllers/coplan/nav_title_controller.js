import { Controller } from "@hotwired/stimulus"

// Fades the plan context (containing-folder control + title) into the sticky top nav
// once the document's own title has scrolled up behind the bar. Persistent wayfinding —
// especially on mobile and on comment deep links, where you land centered
// on an anchor with the title already off-screen — that costs zero
// space while the title is still visible.
export default class extends Controller {
  static values = { anchor: { type: String, default: "plan-title" } }

  connect() {
    // #plan-title is stream-replaced when the plan is renamed, which would
    // strand an observer bound to the old (detached) node. The
    // .plan-document__head wrapper around it is never itself a stream
    // target, so watch that: when it mutates we re-point the
    // IntersectionObserver at the fresh title and re-sync the copy from it.
    // This copy is itself stream-replaced (renames, moves) while the reader
    // may be scrolled down. Take the first state without animating, so a
    // fresh copy appears in place rather than sliding in again.
    this.element.classList.add("site-nav__plan-context--settling")
    this.head = document.querySelector(".plan-document__head")
    this.textEl = this.element.querySelector(".site-nav__doc-title-text")
    this.editEl = this.element.querySelector(".site-nav__edit")
    if (this.editEl) this.editEl.hidden = !document.querySelector('#plan-toolbar a[title^="Edit this document"]')
    this._observeAnchor()

    if (this.head) {
      this._mutation = new MutationObserver(() => {
        this._observeAnchor()
        this._syncTitle()
      })
      this._mutation.observe(this.head, { childList: true, subtree: true, characterData: true })
    }
  }

  disconnect() {
    this._observer?.disconnect()
    this._mutation?.disconnect()
    // Stimulus reuses this instance if the element reconnects; forget the
    // anchor so connect() observes it again.
    this._anchor = null
    this._setVisible(false)
  }

  // Return to the top of the plan. A bare #plan-title jump lands the title
  // under the sticky bar (and reads as "nothing moved"); scroll all the way
  // up instead, so the metadata row and title are back in view — at which
  // point the observer hides this copy on its own.
  scrollToTop(event) {
    event.preventDefault()
    window.scrollTo({ top: 0, behavior: "smooth" })
  }

  edit(event) {
    event.preventDefault()
    document.dispatchEvent(new CustomEvent("coplan:edit-request"))
  }

  // (Re)bind the IntersectionObserver to the current title element. Only
  // rebuilds when the node actually changed, so live typing in the inline
  // title editor doesn't churn the observer.
  _observeAnchor() {
    const anchor = document.getElementById(this.anchorValue)
    if (!anchor || anchor === this._anchor) return
    this._anchor = anchor

    this._observer?.disconnect()
    this._observer = new IntersectionObserver(
      ([entry]) => {
        this._setVisible(!entry.isIntersecting)
        this._settled()
      },
      // Trip the moment the title clears the sticky nav, not the very top
      // of the viewport — otherwise the title would linger under the bar.
      { rootMargin: `-${this._navHeightPx()}px 0px 0px 0px`, threshold: 0 }
    )
    this._observer.observe(anchor)
  }

  // Keep the sticky copy in step with the live title, so a rename that
  // arrives over the wire doesn't leave a stale name pinned to the bar.
  _syncTitle() {
    const title = this.head?.querySelector(".plan-title__heading")?.textContent?.trim()
    if (title && this.textEl && this.textEl.textContent !== title) {
      this.textEl.textContent = title
    }
  }

  _settled() {
    if (!this.element.classList.contains("site-nav__plan-context--settling")) return
    // Two frames: the first paints the state, the second re-enables motion.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      this.element.classList.remove("site-nav__plan-context--settling")
    }))
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
