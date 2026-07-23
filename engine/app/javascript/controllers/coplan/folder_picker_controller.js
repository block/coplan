import { Controller } from "@hotwired/stimulus"

// The folder navigator popover: the viewer's folder tree, a little
// filesystem. Every trigger opens it — Save on someone's plan, "Move to
// folder…" in the plan menu, workspace row fallbacks. Triggers carry the
// plan's move URL, current folder, and saved state; already-saved triggers
// get a "Remove from library" row inside the navigator, so removal is a
// deliberate labeled choice instead of a surprise toggle on the trigger.
export default class extends Controller {
  static targets = ["modal", "title", "heading", "remove", "removeLabel"]

  open(event) {
    event.preventDefault()
    const trigger = event.currentTarget
    this._moveUrl = trigger.dataset.moveUrl
    this._currentFolderId = trigger.dataset.currentFolderId || ""

    if (this.hasHeadingTarget) {
      this.headingTarget.textContent = trigger.dataset.pickerHeading || "Save to library"
    }
    if (this.hasRemoveTarget) {
      this.removeTarget.hidden = trigger.dataset.saved !== "true"
      if (this.hasRemoveLabelTarget) {
        // "Remove" means different things per trigger: a reader letting a
        // saved plan go entirely vs. an owner unfiling their own plan.
        this.removeLabelTarget.textContent = trigger.dataset.removeLabel || "Remove from library"
      }
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

  // The "Remove from library" row inside the navigator (only shown when
  // the trigger was already saved).
  remove() {
    if (!this._moveUrl) return
    this._patch("")
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
