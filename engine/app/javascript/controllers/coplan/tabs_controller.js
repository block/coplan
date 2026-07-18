import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]

  switch(event) {
    event.preventDefault()
    const targetId = event.currentTarget.getAttribute("href").replace("#", "")
    this._activate(targetId, event.currentTarget.dataset.tabName)
  }

  // "+" beside a tab label: activate that tab, then open its add modal.
  // Order matters — a popover inside a still-hidden panel can't render,
  // so the panel must be visible before showPopover().
  openAdd(event) {
    event.preventDefault()
    const { panelId, tabName, modalId } = event.currentTarget.dataset
    this._activate(panelId, tabName)
    const modal = document.getElementById(modalId)
    try { modal?.showPopover() } catch {}
  }

  _activate(targetId, tabName) {
    this.tabTargets.forEach(tab => {
      tab.classList.toggle("plan-tabs__tab--active", tab.getAttribute("href") === `#${targetId}`)
    })

    this.panelTargets.forEach(panel => {
      panel.classList.toggle("plan-tabs__panel--hidden", panel.id !== targetId)
    })

    // Update URL with tab param (omit for default "content" tab)
    const url = new URL(window.location)
    if (tabName && tabName !== "content") {
      url.searchParams.set("tab", tabName)
    } else {
      url.searchParams.delete("tab")
    }
    history.replaceState(null, "", url)
  }
}
