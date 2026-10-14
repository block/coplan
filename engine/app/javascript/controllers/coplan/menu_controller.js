import { Controller } from "@hotwired/stimulus"

// A small dropdown menu on the native Popover API (light-dismiss and Esc
// for free). Popovers open centered by default; this anchors the menu
// under its trigger's right edge on every open, and closes it on scroll
// so it never floats away from the button.
export default class extends Controller {
  static targets = ["trigger", "menu"]

  reposition(event) {
    if (event.newState !== "open") {
      this.#stopWatchingScroll()
      return
    }
    const rect = this.triggerTarget.getBoundingClientRect()
    const menu = this.menuTarget
    menu.style.position = "fixed"
    menu.style.margin = "0"
    menu.style.top = `${rect.bottom + 6}px`
    menu.style.left = "auto"
    // The root's rendered right edge accounts for scrollbar-gutter: stable;
    // innerWidth and clientWidth still include that reserved strip in Chrome.
    menu.style.right = `${Math.max(document.documentElement.getBoundingClientRect().right - rect.right, 8)}px`
    this.#watchScroll()
  }

  close() {
    try { this.menuTarget.hidePopover() } catch {}
  }

  showOutline() {
    this.close()
    this.dispatch("show-outline", { prefix: "coplan", detail: { trigger: this.triggerTarget } })
  }

  disconnect() {
    this.#stopWatchingScroll()
  }

  #watchScroll() {
    this.scrollHandler ||= () => this.close()
    window.addEventListener("scroll", this.scrollHandler, { passive: true, once: true })
  }

  #stopWatchingScroll() {
    if (this.scrollHandler) window.removeEventListener("scroll", this.scrollHandler)
  }
}
