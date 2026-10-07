import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["visibility", "visibilityError", "visibilityButton"]

  visibilityButtonTargetConnected(button) {
    if (!this.visibilityOwnsFocus && (!this.pendingVisibilityFocus || button.dataset.visibility !== this.pendingVisibilityFocus)) return
    button.focus({ preventScroll: true })
    this.visibilityOwnsFocus = true
    this.pendingVisibilityFocus = null
  }

  visibilityFocused() { this.visibilityOwnsFocus = true }

  visibilityBlurred(event) {
    // Removal during a stream replacement isn't a user moving focus.
    const button = event.currentTarget
    queueMicrotask(() => {
      if (button.isConnected && document.activeElement !== button) this.visibilityOwnsFocus = false
    })
  }

  manageReviews() {
    document.dispatchEvent(new CustomEvent("coplan:manage-reviews"))
  }

  jumpReviews(event) {
    event.preventDefault()
    const log = document.getElementById("footnote-approvals")
    if (!log) return
    log.scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth", block: "start" })
    log.focus({ preventScroll: true })
  }

  openVisibility(event) {
    const state = event.currentTarget.dataset.visibility
    this.visibilityErrorTarget.textContent = ""
    this.visibilityTarget.querySelectorAll('[data-visibility-option]').forEach(option => {
      const selected = option.dataset.visibilityOption === state
      option.querySelector('button')?.toggleAttribute('disabled', selected)
      option.classList.toggle('visibility-option--selected', selected)
    })
    this.visibilityTarget.showPopover()
    const rect = event.currentTarget.getBoundingClientRect(), panel = this.visibilityTarget
    panel.style.left = `${Math.max(8, Math.min(rect.left, document.documentElement.clientWidth - panel.offsetWidth - 8))}px`
    panel.style.top = `${Math.max(8, Math.min(rect.bottom + 8, innerHeight - panel.offsetHeight - 8))}px`
    const focusTarget = panel.querySelector('button:not(:disabled)') || panel
    focusTarget.focus({ preventScroll: true })
  }

  dismissVisibility(event) {
    if (!this.visibilityTarget.matches(':popover-open')) return
    event.preventDefault()
    this.visibilityTarget.hidePopover()
    this.element.querySelector('.plan-visibility-button')?.focus({ preventScroll: true })
  }

  visibilitySubmitted(event) {
    if (event.detail.success) {
      this.visibilityTarget.hidePopover()
      // Turbo may replace the byline before or after submit-end. Restore
      // focus only once its new button reflects the completed action.
      this.pendingVisibilityFocus = event.target.closest('[data-visibility-option]')?.dataset.visibilityOption
      if (this.hasVisibilityButtonTarget) this.visibilityButtonTargetConnected(this.visibilityButtonTarget)
    }
    else this.visibilityErrorTarget.textContent = "Couldn't change visibility. Please try again."
  }
}
