import { Controller } from "@hotwired/stimulus"

// The "save to library" navigator: a bookmark/move trigger opens a popover
// with the viewer's folder tree (a little filesystem), picking a folder
// files the plan there, "Remove from library" unfiles it. One shared popover
// per page — triggers carry the plan's move URL and current folder so rows
// and the plan header can all reuse it.
export default class extends Controller {
  static targets = ["modal", "title", "remove"]

  open(event) {
    event.preventDefault()
    const trigger = event.currentTarget
    this._moveUrl = trigger.dataset.moveUrl
    this._currentFolderId = trigger.dataset.currentFolderId || ""

    if (this.hasTitleTarget && trigger.dataset.planTitle) {
      this.titleTarget.textContent = trigger.dataset.planTitle
    }
    // "Remove" only makes sense when the plan is actually shelved.
    if (this.hasRemoveTarget) {
      this.removeTarget.hidden = this._currentFolderId === ""
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

  _patch(folderId) {
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
        const message = data.message || "Saved."
        // Re-render so shelves, breadcrumbs, and counts stay accurate,
        // then toast on the fresh page.
        if (window.Turbo) {
          document.addEventListener("turbo:load", () => this._toast(message, "notice"), { once: true })
          window.Turbo.visit(window.location.href, { action: "replace" })
        } else {
          this._toast(message, "notice")
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
