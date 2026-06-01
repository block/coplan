import { Controller } from "@hotwired/stimulus"

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
  static targets = ["input", "body"]
  static values = {
    url: String,
    debounce: { type: Number, default: 150 }
  }

  connect() {
    this._onGlobalKeydown = this._onGlobalKeydown.bind(this)
    document.addEventListener("keydown", this._onGlobalKeydown)
    this._selectedIndex = -1
    this._debounceTimer = null
  }

  disconnect() {
    document.removeEventListener("keydown", this._onGlobalKeydown)
    if (this._debounceTimer) clearTimeout(this._debounceTimer)
  }

  // Fires when the popover opens or closes (newState: "open" | "closed").
  onToggle(event) {
    if (event.newState === "open") {
      // Focus the input and clear it so each open starts fresh.
      requestAnimationFrame(() => {
        this.inputTarget.focus()
        this.inputTarget.select()
      })
    } else {
      this._cancelDebounce()
    }
  }

  // Debounced input handler — schedules a frame fetch.
  onInput() {
    this._cancelDebounce()
    this._debounceTimer = setTimeout(() => this._fetchResults(), this.debounceValue)
  }

  // Keyboard nav within the input box.
  onKeydown(event) {
    const items = this._resultItems()
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this._moveSelection(1, items)
        break
      case "ArrowUp":
        event.preventDefault()
        this._moveSelection(-1, items)
        break
      case "Enter":
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

  _onGlobalKeydown(event) {
    if (event.key !== "/") return
    if (event.metaKey || event.ctrlKey || event.altKey) return
    const t = event.target
    if (!t) return
    const tag = t.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || t.isContentEditable) return
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
    frame.src = url.toString()
    // Reset selection — the frame is about to be replaced.
    this._selectedIndex = -1
    frame.addEventListener("turbo:frame-load", () => this._afterFrameLoad(), { once: true })
  }

  _afterFrameLoad() {
    const items = this._resultItems()
    if (items.length > 0) {
      this._selectedIndex = 0
      this._applySelection(items)
    }
  }

  _resultItems() {
    return Array.from(this.bodyTarget.querySelectorAll("[data-search-result]"))
  }

  _moveSelection(delta, items) {
    if (items.length === 0) return
    this._selectedIndex = (this._selectedIndex + delta + items.length) % items.length
    this._applySelection(items)
  }

  _applySelection(items) {
    items.forEach((el, i) => {
      const selected = i === this._selectedIndex
      el.classList.toggle("search-modal__result--selected", selected)
      el.setAttribute("aria-selected", selected ? "true" : "false")
      if (selected) {
        el.scrollIntoView({ block: "nearest" })
      }
    })
  }
}
