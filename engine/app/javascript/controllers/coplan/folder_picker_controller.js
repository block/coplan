import { Controller } from "@hotwired/stimulus"

// The "save to library" bookmark. Behaves like a browser bookmark star:
// unsaved, a click opens the folder navigator popover (the viewer's folder
// tree, a little filesystem) to pick where it goes; saved, a click just
// removes it — no dialog, no toast — and you can re-add if you want. One
// shared popover per page — triggers carry the plan's move URL, current
// folder, and saved state so rows and the plan header can all reuse it.
export default class extends Controller {
  static targets = ["modal", "title"]

  open(event) {
    event.preventDefault()
    const trigger = event.currentTarget
    this._moveUrl = trigger.dataset.moveUrl
    this._currentFolderId = trigger.dataset.currentFolderId || ""

    // Already saved: the second click unbookmarks, quietly.
    if (trigger.dataset.saved === "true") {
      this._patch("", { quiet: true })
      return
    }

    if (this.hasTitleTarget && trigger.dataset.planTitle) {
      this.titleTarget.textContent = trigger.dataset.planTitle
    }
    // Mark where the plan currently sits so the tree reads as state, not
    // just a menu.
    this.modalTarget.querySelectorAll(".folder-picker__option").forEach(option => {
      option.classList.toggle("folder-picker__option--current",
        (option.dataset.folderId || "") === this._currentFolderId && this._currentFolderId !== "")
    })

    try { this.modalTarget.showPopover() } catch {}
  }

  choose(event) {
    const folderId = event.currentTarget.dataset.folderId || ""
    if (!this._moveUrl) return
    // Filing it where it already is: quietly close instead of a no-op PATCH.
    if (folderId === this._currentFolderId) {
      try { this.modalTarget.hidePopover() } catch {}
      return
    }
    this._patch(folderId)
  }

  _patch(folderId, { quiet = false } = {}) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this._moveUrl, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": token,
      },
      body: JSON.stringify({ folder_id: folderId }),
    })
      .then(async response => {
        const data = await response.json().catch(() => ({}))
        if (!response.ok) throw new Error(data.error || "Move failed")
        try { this.modalTarget.hidePopover() } catch {}
        // Re-render so shelves, breadcrumbs, and counts stay accurate —
        // with a toast on the fresh page when the action deserves one
        // (unbookmarking is quiet, like any bookmark star).
        if (!quiet && window.Turbo) {
          const message = data.message || "Saved."
          document.addEventListener("turbo:load", () => this._toast(message, "notice"), { once: true })
        }
        if (window.Turbo) {
          window.Turbo.visit(window.location.href, { action: "replace" })
        } else if (!quiet) {
          this._toast(data.message || "Saved.", "notice")
        }
      })
      .catch(error => this._toast(error.message, "alert"))
  }

  _toast(message, kind) {
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
