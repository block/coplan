import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { planId: String, revision: Number, toggleUrl: String }
  static targets = ["checkbox"]

  toggle(event) {
    const checkbox = event.target
    const lineText = checkbox.dataset.lineText
    if (!lineText) return
    if (this.inflight) { checkbox.checked = !checkbox.checked; return }

    const nowChecked = checkbox.checked
    const oldText = lineText
    const newText = nowChecked
      ? lineText.replace(/([*+-]\s+)\[[ ]\]/, "$1[x]")
      : lineText.replace(/([*+-]\s+)\[[xX]\]/, "$1[ ]")

    // Optimistic UI: update immediately
    checkbox.dataset.lineText = newText
    const li = checkbox.closest("li")
    if (li) {
      li.classList.toggle("task-list-item--checked", nowChecked)
    }

    this.inflight = true
    this.#sendToggle({ checkbox, li, oldText, newText, nowChecked, retried: false })
  }

  #sendToggle({ checkbox, li, oldText, newText, nowChecked, retried }) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(this.toggleUrlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token,
        "Accept": "application/json"
      },
      body: JSON.stringify({
        old_text: oldText,
        new_text: newText,
        base_revision: this.revisionValue
      })
    }).then(response => {
      if (response.ok) {
        return response.json().then(data => {
          this.revisionValue = data.revision
          this.inflight = false
        })
      } else if (response.status === 409 && !retried) {
        // Conflict: someone else edited. Update revision and retry once.
        return response.json().then(data => {
          if (data.current_revision) {
            this.revisionValue = data.current_revision
          }
          this.#sendToggle({ checkbox, li, oldText, newText, nowChecked, retried: true })
        })
      } else {
        this.#revert(checkbox, li, oldText, nowChecked)
      }
    }).catch(() => {
      this.#revert(checkbox, li, oldText, nowChecked)
    })
  }

  #revert(checkbox, li, oldText, nowChecked) {
    checkbox.checked = !nowChecked
    checkbox.dataset.lineText = oldText
    if (li) li.classList.toggle("task-list-item--checked", !nowChecked)
    this.inflight = false
  }
}
