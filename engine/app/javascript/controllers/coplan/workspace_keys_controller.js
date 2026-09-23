import { Controller } from "@hotwired/stimulus"
import { registerShortcuts, commandFor } from "coplan/shortcuts"

// Keyboard navigation for the workspace file browser:
//
//   j / k, ↓ / ↑ step down/up through folders and plans
//   Enter        open the selected folder or plan
//   Backspace    go up one folder level (breadcrumb parent)
//   Escape       clear active filters; with none, jump back to the root
//
// Items register via the "item" target (folder rows and plan rows alike),
// so lazily-loaded pagination frames join the ring automatically.
const SELECTED_CLASS = "workspace-key-selected"

export default class extends Controller {
  static targets = ["item"]

  connect() {
    this.releaseShortcuts = registerShortcuts(this, "library", event => this._handleKeydown(event))
  }

  disconnect() {
    this.releaseShortcuts()
  }

  _handleKeydown(event) {
    // A focused button/link/summary owns its activation keys — a keyboard
    // user tabbed to "New folder" must get the button, not the selected row.
    const activation = !!event.target.closest("a, button, summary")

    switch (commandFor("library", event)) {
      case "next":
        event.preventDefault()
        this._move(1)
        break
      case "previous":
        event.preventDefault()
        this._move(-1)
        break
      case "open":
        if (!activation && this._selected()) {
          event.preventDefault()
          this._open(this._selected())
        }
        break
      case "up":
        if (activation) return
        event.preventDefault()
        this._goUp()
        break
      case "home":
        this._clearOrGoHome(event)
        break
    }
  }

  _move(delta) {
    const items = this.itemTargets
    if (items.length === 0) return

    const current = this._selected()
    let index = current ? items.indexOf(current) : -1
    index = Math.min(items.length - 1, Math.max(0, index + delta))

    items.forEach(item => item.classList.remove(SELECTED_CLASS))
    const next = items[index]
    next.classList.add(SELECTED_CLASS)
    next.scrollIntoView({ block: "nearest" })
  }

  _selected() {
    return this.itemTargets.find(item => item.classList.contains(SELECTED_CLASS))
  }

  _open(item) {
    const url = item.dataset.planUrl || item.getAttribute("href")
    if (url && window.Turbo) window.Turbo.visit(url)
  }

  _goUp() {
    // Crumbs are [root, ...ancestors, current]; "up" is the one before
    // current. At root, the only crumb is current — nowhere to go.
    const crumbs = Array.from(this.element.querySelectorAll(".workspace-crumbs__crumb"))
    if (crumbs.length < 2) return
    const up = crumbs[crumbs.length - 2]
    if (window.Turbo) window.Turbo.visit(up.href)
  }

  _clearOrGoHome(event) {
    const clear = this.element.querySelector(".active-filter__clear")
    if (clear) {
      event.preventDefault()
      if (window.Turbo) window.Turbo.visit(clear.href)
      return
    }
    const root = this.element.querySelector(".workspace-crumbs__crumb")
    if (root && !root.classList.contains("workspace-crumbs__crumb--current")) {
      event.preventDefault()
      if (window.Turbo) window.Turbo.visit(root.href)
    }
  }

}
