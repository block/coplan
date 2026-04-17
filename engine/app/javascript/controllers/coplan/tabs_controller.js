import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]

  switch(event) {
    event.preventDefault()
    const targetId = event.currentTarget.getAttribute("href").replace("#", "")
    const tabName = event.currentTarget.dataset.tabName

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
