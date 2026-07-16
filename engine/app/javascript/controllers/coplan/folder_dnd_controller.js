import { Controller } from "@hotwired/stimulus"

// HTML5 drag & drop: drag a plan row (author only — rows are only marked
// draggable for the author) onto a sidebar folder to move the plan there.
// On success we show a toast, then refresh the page so row breadcrumbs,
// group counts, and sidebar folder counts all re-render consistently.
// No-JS fallback: each draggable row also has a "Move to folder" menu that
// submits a plain form to the same endpoint.
const PLAN_MIME = "application/x-coplan-plan"

export default class extends Controller {
  static targets = ["folder"]

  dragStart(event) {
    const row = event.currentTarget
    event.dataTransfer.effectAllowed = "move"
    // The move URL rides along in the drag payload (readable on drop).
    event.dataTransfer.setData(PLAN_MIME, row.dataset.moveUrl)
    event.dataTransfer.setData("text/plain", row.dataset.planId)
    row.classList.add("plan-row--dragging")
    this.element.classList.add("workspace--dragging")
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("plan-row--dragging")
    this.element.classList.remove("workspace--dragging")
  }

  dragOver(event) {
    if (!event.dataTransfer.types.includes(PLAN_MIME)) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    event.currentTarget.classList.add("folder-tree__link--drop")
  }

  dragLeave(event) {
    event.currentTarget.classList.remove("folder-tree__link--drop")
  }

  drop(event) {
    if (!event.dataTransfer.types.includes(PLAN_MIME)) return
    event.preventDefault()
    const target = event.currentTarget
    target.classList.remove("folder-tree__link--drop")
    const moveUrl = event.dataTransfer.getData(PLAN_MIME)
    if (!moveUrl) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(moveUrl, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": token,
      },
      body: JSON.stringify({ folder_id: target.dataset.folderId || "" }),
    })
      .then(async response => {
        const data = await response.json().catch(() => ({}))
        if (!response.ok) throw new Error(data.error || "Move failed")
        // Re-render so breadcrumbs and folder/group counts stay accurate,
        // then toast on the fresh page.
        const message = data.message || "Plan moved."
        if (window.Turbo) {
          document.addEventListener("turbo:load", () => this.#toast(message, "notice"), { once: true })
          window.Turbo.visit(window.location.href, { action: "replace" })
        } else {
          this.#toast(message, "notice")
        }
      })
      .catch(error => this.#toast(error.message, "alert"))
  }

  #toast(message, kind) {
    let container = document.getElementById("coplan-toasts")
    if (!container) {
      container = document.createElement("div")
      container.id = "coplan-toasts"
      container.className = "toasts"
      document.body.appendChild(container)
    }
    const toast = document.createElement("div")
    toast.className = `flash flash--${kind} toasts__toast`
    toast.setAttribute("role", "status")
    toast.textContent = message
    container.appendChild(toast)
    setTimeout(() => toast.remove(), 4000)
  }
}
