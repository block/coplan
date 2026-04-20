import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    const first = this.element.querySelector(".history-split__item")
    if (first) {
      first.classList.add("history-split__item--active")
    }
  }

  select(event) {
    this.element.querySelectorAll(".history-split__item--active").forEach(el => {
      el.classList.remove("history-split__item--active")
    })
    event.currentTarget.classList.add("history-split__item--active")
  }
}
