import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]

  switch(event) {
    event.preventDefault()
    const targetId = event.currentTarget.getAttribute("href").replace("#", "")

    this.tabTargets.forEach(tab => {
      tab.classList.toggle("plan-tabs__tab--active", tab.getAttribute("href") === `#${targetId}`)
    })

    this.panelTargets.forEach(panel => {
      panel.classList.toggle("plan-tabs__panel--hidden", panel.id !== targetId)
    })
  }
}
