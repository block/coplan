import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    // Cached images can finish before Stimulus binds the load/error actions.
    if (this.element.complete) {
      if (this.element.naturalWidth > 0) this.loaded()
      else this.failed()
    }
  }

  loaded() {
    this.element.classList.add("avatar__image--loaded")
  }

  failed() {
    this.element.remove()
  }
}
