import { Controller } from "@hotwired/stimulus"

// Opens the status menu from the status badge in the plan header. The badge
// lives inside the broadcast-replaced #plan-header (rendered without a
// current_user), so the policy-gated menu renders outside it and this
// controller spans both: the badge only becomes interactive when a menu is
// present for this viewer.
export default class extends Controller {
  static targets = ["badge", "menu"]

  badgeTargetConnected(badge) {
    if (!this.hasMenuTarget) return
    badge.setAttribute("role", "button")
    badge.setAttribute("tabindex", "0")
    badge.setAttribute("title", "Change status")
    badge.classList.add("badge--menu")
  }

  toggle(event) {
    if (!this.hasMenuTarget) return
    const menu = this.menuTarget
    if (menu.style.display === "none") {
      const rect = event.currentTarget.getBoundingClientRect()
      menu.style.position = "fixed"
      menu.style.top = `${rect.bottom + 4}px`
      menu.style.left = `${rect.left}px`
      menu.style.right = "auto"
      menu.style.display = ""
    } else {
      menu.style.display = "none"
    }
  }

  close(event) {
    if (!this.hasMenuTarget) return
    const insideBadge = this.hasBadgeTarget && this.badgeTarget.contains(event.target)
    if (!this.menuTarget.contains(event.target) && !insideBadge) {
      this.menuTarget.style.display = "none"
    }
  }

  connect() {
    this._closeHandler = this.close.bind(this)
    document.addEventListener("click", this._closeHandler)
  }

  disconnect() {
    document.removeEventListener("click", this._closeHandler)
  }
}
