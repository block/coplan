import { Controller } from "@hotwired/stimulus"
import { registerShortcuts, commandFor } from "coplan/shortcuts"

// Sitewide search modal controller.
//
// Responsibilities:
//   1. Open the modal on "/" pressed anywhere outside an input/textarea/CE.
//   2. Debounce input → swap the inner `<turbo-frame id="search-results">`
//      by setting its `src` attribute, which triggers Turbo to fetch and
//      replace the frame body.
//   3. Arrow ↑/↓ moves the "selected" result; Enter activates it; Esc closes
//      (Esc is also handled natively by `popover="auto"`).
//
// The modal element itself is `[popover="auto"]`; we open/close it via
// element.showPopover() / hidePopover() — the browser handles the backdrop,
// top-layer, and outside-click dismiss.
export default class extends Controller {
  static targets = ["input", "body", "announcement"]
  static values = {
    url: String,
    debounce: { type: Number, default: 150 }
  }

  connect() {
    this.releaseShortcuts = registerShortcuts(this, "search", event => this._onGlobalKeydown(event))
    this._selectedIndex = -1
    this._debounceTimer = null
  }

  disconnect() {
    this.releaseShortcuts()
    if (this._debounceTimer) clearTimeout(this._debounceTimer)
    this._openingAnimation?.cancel()
  }

  // Fires when the popover opens or closes (newState: "open" | "closed").
  onToggle(event) {
    if (event.newState === "open") {
      // Select the query so reopening search is ready for new input.
      requestAnimationFrame(() => {
        if (!this.element.matches(":popover-open")) return
        this._animateOpen()
        this.inputTarget.focus()
        this.inputTarget.select()
        this.resultsLoaded()
      })
    } else {
      this._openingAnimation?.cancel()
      this._cancelDebounce()
      this.inputTarget.setAttribute("aria-expanded", "false")
      this.inputTarget.removeAttribute("aria-activedescendant")
    }
  }

  // Debounced input handler — schedules a frame fetch.
  onInput() {
    this._cancelDebounce()
    this._selectedIndex = -1
    this._applySelection(this._resultItems())
    this._debounceTimer = setTimeout(() => this._fetchResults(), this.debounceValue)
  }

  // Keyboard nav within the input box.
  onKeydown(event) {
    if (event.isComposing) return
    if (event.key === "Escape") {
      event.preventDefault()
      this.element.hidePopover()
      return
    }
    const items = this._resultItems()
    switch (commandFor("results", event)) {
      case "next":
        event.preventDefault()
        this._moveSelection(1, items)
        break
      case "previous":
        event.preventDefault()
        this._moveSelection(-1, items)
        break
      case "open":
        if (this._selectedIndex >= 0 && items[this._selectedIndex]) {
          event.preventDefault()
          items[this._selectedIndex].click()
        }
        break
    }
  }

  // Clicking a recent-search row pre-fills the input and triggers a search.
  selectRecent(event) {
    event.preventDefault()
    const query = event.currentTarget.dataset.searchRecentQuery
    this.inputTarget.value = query
    this._cancelDebounce()
    this._fetchResults()
  }

  // --- private ---

  _animateOpen() {
    this._openingAnimation?.cancel()
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    const trigger = document.querySelector(`[popovertarget="${this.element.id}"]`)
    if (!trigger) return
    const origin = trigger.getBoundingClientRect()
    const destination = this.element.getBoundingClientRect()
    if (!origin.width || !origin.height || !destination.width || !destination.height) return
    const x = origin.left + origin.width / 2 - destination.left - destination.width / 2
    const y = origin.top + origin.height / 2 - destination.top - destination.height / 2
    this._openingAnimation = this.element.animate([
      { transform: `translateX(-50%) translate(${x}px, ${y}px) scale(${origin.width / destination.width}, ${origin.height / destination.height})`, opacity: 0 },
      { transform: "translateX(-50%) translate(0, 0) scale(1, 1)", opacity: 1 }
    ], { duration: 180, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" })
  }

  _onGlobalKeydown(event) {
    if (commandFor("search", event) !== "open") return
    event.preventDefault()
    this.element.showPopover()
  }

  _cancelDebounce() {
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer)
      this._debounceTimer = null
    }
  }

  _fetchResults() {
    const query = this.inputTarget.value.trim()
    const frame = this.bodyTarget.querySelector("turbo-frame#search-results")
    if (!frame) return
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("q", query)
    url.searchParams.set("frame", "results")
    // Reset selection — the frame is about to be replaced.
    this._selectedIndex = -1
    this._applySelection([])
    this.announcementTarget.textContent = "Searching…"
    frame.src = url.toString()
  }

  resultsLoaded(event) {
    if (event && event.target.id !== "search-results") return
    const listbox = this.bodyTarget.querySelector("#search-results-listbox")
    if (listbox?.dataset.searchQuery !== this.inputTarget.value.trim()) return
    const items = this._resultItems()
    this._selectedIndex = items.length > 0 ? 0 : -1
    this._applySelection(items)
    this.announcementTarget.textContent = this.bodyTarget.querySelector("[data-search-summary]")?.textContent || ""
  }

  _resultItems() {
    const listbox = this.bodyTarget.querySelector("#search-results-listbox")
    if (listbox?.dataset.searchQuery !== this.inputTarget.value.trim()) return []
    return Array.from(this.bodyTarget.querySelectorAll("[data-search-result]"))
  }

  _moveSelection(delta, items) {
    if (items.length === 0) return
    this._selectedIndex = (this._selectedIndex + delta + items.length) % items.length
    this._applySelection(items)
  }

  _applySelection(items) {
    const open = this.element.matches(":popover-open")
    this.inputTarget.setAttribute("aria-expanded", String(open && items.length > 0))
    this.inputTarget.removeAttribute("aria-activedescendant")
    this.bodyTarget.querySelectorAll(".search-modal__result--selected").forEach(el => {
      el.classList.remove("search-modal__result--selected")
      el.setAttribute("aria-selected", "false")
    })
    items.forEach((el, i) => {
      const selected = i === this._selectedIndex
      el.classList.toggle("search-modal__result--selected", selected)
      el.setAttribute("aria-selected", selected ? "true" : "false")
      if (selected && open) {
        this.inputTarget.setAttribute("aria-activedescendant", el.id)
        el.scrollIntoView({ block: "nearest" })
      }
    })
  }
}
