import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.key = `coplan-support:${window.location.pathname}:${this.element.closest("[id]").id}`
    try {
      const saved = sessionStorage.getItem(this.key)
      if (saved !== null) this.element.open = saved === "true"
    } catch { /* Storage may be unavailable; the disclosure still works. */ }
  }

  remember() {
    try { sessionStorage.setItem(this.key, String(this.element.open)) } catch { /* Keep the local state. */ }
  }
}
