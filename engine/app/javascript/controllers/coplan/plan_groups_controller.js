import { Controller } from "@hotwired/stimulus"

// Collapsible plan groups on the plans index (one per root folder, plus
// Unfiled). Collapsed state is persisted per user in localStorage, keyed
// by data-group-key; groups marked with [data-default-collapsed] start
// collapsed until the user explicitly expands them.
const STORAGE_KEY = "coplan:plans:collapsed-groups"

export default class extends Controller {
  static targets = ["group"]

  connect() {
    this.groupTargets.forEach(group => this.#apply(group))
  }

  toggle(event) {
    const group = event.currentTarget.closest("[data-group-key]")
    if (!group) return

    const state = this.#readState()
    state[group.dataset.groupKey] = !this.#isCollapsed(group, state)
    this.#writeState(state)
    this.#apply(group)
  }

  #apply(group) {
    const collapsed = this.#isCollapsed(group, this.#readState())
    group.classList.toggle("plan-group--collapsed", collapsed)
    const button = group.querySelector(".plan-group__toggle")
    if (button) button.setAttribute("aria-expanded", String(!collapsed))
    // hidden takes collapsed content out of the accessibility tree, not
    // just off-screen.
    const body = group.querySelector(".plan-group__body")
    if (body) body.hidden = collapsed
  }

  #isCollapsed(group, state) {
    const key = group.dataset.groupKey
    if (Object.prototype.hasOwnProperty.call(state, key)) return Boolean(state[key])
    return group.hasAttribute("data-default-collapsed")
  }

  #readState() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {}
    } catch {
      return {}
    }
  }

  #writeState(state) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
    } catch {
      // localStorage unavailable (private mode etc.) — collapse still works
      // for the current page, it just won't persist.
    }
  }
}
