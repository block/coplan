import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "panel"]
  static classes = ["active"]

  switch(event) {
    const index = parseInt(event.currentTarget.dataset.index)

    this.tabTargets.forEach((tab, i) => {
      tab.classList.toggle(this.activeClass, i === index)
    })

    this.panelTargets.forEach((panel, i) => {
      panel.style.display = i === index ? "" : "none"
    })
  }
}
