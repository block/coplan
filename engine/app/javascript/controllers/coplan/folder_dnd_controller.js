import { Controller } from "@hotwired/stimulus"

// HTML5 drag & drop for the workspace's filing tree. Two payloads:
//
// - Plan rows → drop on a folder (sidebar link or main-pane group heading)
//   to shelve the plan there; drop on "Everything"/"Unfiled" to unshelve.
// - Folders → drop on another folder to nest it, or on a top-level target
//   to make it a root folder. The server validates cycles and the depth cap.
//
// On success we show a toast, then refresh the page so row breadcrumbs,
// group counts, and sidebar folder counts all re-render consistently.
// No-JS fallback: each draggable row also has a "Move to folder" menu that
// submits a plain form to the same endpoint.
const PLAN_MIME = "application/x-coplan-plan"
const FOLDER_MIME = "application/x-coplan-folder"
const DROP_CLASS = "dnd-drop"

export default class extends Controller {

  dragStart(event) {
    const row = event.currentTarget
    event.dataTransfer.effectAllowed = "move"
    // The move URL and current folder ride along in the drag payload
    // (readable on drop) — the folder so a drop where the plan already
    // lives is a quiet no-op instead of a PATCH + reload + "moved" toast.
    event.dataTransfer.setData(PLAN_MIME, JSON.stringify({
      url: row.dataset.moveUrl,
      folderId: row.dataset.currentFolderId || "",
    }))
    event.dataTransfer.setData("text/plain", row.dataset.planId)
    row.classList.add("plan-row--dragging")
    this.element.classList.add("workspace--dragging")
  }

  dragEnd(event) {
    event.currentTarget.classList.remove("plan-row--dragging")
    this.element.classList.remove("workspace--dragging")
  }

  folderDragStart(event) {
    // Folder links sit inside <summary>/<a> stacks — don't let the event
    // bubble into any other draggable ancestor.
    event.stopPropagation()
    const node = event.currentTarget
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData(FOLDER_MIME, JSON.stringify({
      url: node.dataset.reparentUrl,
      id: node.dataset.folderId,
      parentId: node.dataset.parentId || "",
    }))
    event.dataTransfer.setData("text/plain", node.dataset.folderId)
    node.classList.add("folder-tree__link--dragging")
    this.element.classList.add("workspace--dragging")
  }

  folderDragEnd(event) {
    event.currentTarget.classList.remove("folder-tree__link--dragging")
    this.element.classList.remove("workspace--dragging")
  }

  dragOver(event) {
    if (!this.#accepts(event)) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    event.currentTarget.classList.add(DROP_CLASS)
  }

  dragLeave(event) {
    event.currentTarget.classList.remove(DROP_CLASS)
  }

  drop(event) {
    if (!this.#accepts(event)) return
    event.preventDefault()
    const target = event.currentTarget
    target.classList.remove(DROP_CLASS)

    const targetFolderId = target.dataset.folderId || ""

    if (event.dataTransfer.types.includes(FOLDER_MIME)) {
      let payload = {}
      try { payload = JSON.parse(event.dataTransfer.getData(FOLDER_MIME)) } catch {}
      if (!payload.url) return
      // Dropping a folder on itself or where it already sits is a quiet
      // no-op, not a PATCH + reload + toast.
      if (payload.id && payload.id === targetFolderId) return
      if ((payload.parentId || "") === targetFolderId) return
      this.#patch(payload.url, { parent_id: targetFolderId }, "Folder moved.")
    } else {
      let payload = {}
      try { payload = JSON.parse(event.dataTransfer.getData(PLAN_MIME)) } catch {}
      if (!payload.url) return
      // Same quiet no-op when the plan is already filed right here.
      if ((payload.folderId || "") === targetFolderId) return
      this.#patch(payload.url, { folder_id: targetFolderId }, "Plan moved.")
    }
  }

  #accepts(event) {
    const types = event.dataTransfer.types
    return types.includes(PLAN_MIME) || types.includes(FOLDER_MIME)
  }

  #patch(url, body, fallbackMessage) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": token,
      },
      body: JSON.stringify(body),
    })
      .then(async response => {
        const data = await response.json().catch(() => ({}))
        if (!response.ok) throw new Error(data.error || "Move failed")
        // Re-render so breadcrumbs and folder/group counts stay accurate,
        // then toast on the fresh page.
        const message = data.message || fallbackMessage
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
