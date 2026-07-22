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
const BUSY_CLASS = "dnd-drop--busy"

// Spring-loaded folders, Finder-style: hover a drag over a folder, it
// pulses twice, then springs open.
//
// - Sidebar: a collapsed tree branch expands in place (and snaps shut when
//   the drag moves off it), so you can dive multiple levels while dragging.
// - Main pane: springing a folder row (or a breadcrumb, to go up) TUNNELS —
//   the pane temporarily becomes that folder's real level view, exactly as
//   if you'd navigated, prefetched during the pulses. Keep tunneling deeper
//   through its folder rows; drop anywhere in the pane (dead space included)
//   to file right there; end the drag without dropping and the original
//   pane is restored untouched.
const SPRING_CLASS = "dnd-spring"
const SPRING_DELAY = 650 // two 0.3s pulses, then open

export default class extends Controller {

  connect() {
    // Swallow the click some browsers fire on the source link right after a
    // drag — press-drag-release must never read as "open the plan".
    this.element.addEventListener("click", this.#clickGuard, true)
    // Watch where the drag actually is, workspace-wide: a pending spring is
    // cancelled and sprung-open sidebar branches snap shut as soon as the
    // cursor moves somewhere they don't contain. Capture phase: targets
    // stop dragover propagation (innermost target wins), which must not
    // starve this sweep.
    this.element.addEventListener("dragover", this.#springSweep, true)
    this.springs = []
  }

  disconnect() {
    this.element.removeEventListener("click", this.#clickGuard, true)
    this.element.removeEventListener("dragover", this.#springSweep, true)
    this.#cancelPendingSpring()
    this.#collapseAllSprings()
    this.#restoreTunnel()
  }

  #clickGuard = (event) => {
    if (!this.dragHappened) return
    event.preventDefault()
    event.stopPropagation()
  }

  #springSweep = (event) => {
    const over = event.target
    if (over === this.lastSweepTarget) return
    this.lastSweepTarget = over
    if (this.springPendingEl && !this.springPendingEl.contains(over)) this.#cancelPendingSpring()
    // Close sprung folders newest-first until one still holds the cursor.
    while (this.springs.length) {
      const top = this.springs[this.springs.length - 1]
      if (top.keepAlive.some(el => el.contains(over))) break
      this.springs.pop().close()
    }
  }

  dragStart(event) {
    const row = event.currentTarget
    this.dragHappened = true
    this.dragActive = true
    this.dragSourceEl = row
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
    // The stray post-drag click (when it comes at all) fires before timers,
    // so a 0ms clear still covers it without eating the next real click.
    this.#dragCleanup()
  }

  folderDragStart(event) {
    // Folder links sit inside <summary>/<a> stacks — don't let the event
    // bubble into any other draggable ancestor.
    event.stopPropagation()
    const node = event.currentTarget
    this.dragHappened = true
    this.dragActive = true
    this.dragSourceEl = node
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
    this.#dragCleanup()
  }

  dragOver(event) {
    if (!this.#accepts(event)) return
    event.preventDefault()
    // Innermost target wins: a folder row inside the pane highlights alone,
    // without also lighting up the pane-wide target behind it.
    event.stopPropagation()
    event.dataTransfer.dropEffect = "move"
    const target = event.currentTarget
    // Exactly one live target at a time (also mops up any highlight a
    // missed dragleave left behind).
    this.element.querySelectorAll(`.${DROP_CLASS}`).forEach(el => {
      if (el !== target) el.classList.remove(DROP_CLASS)
    })
    target.classList.add(DROP_CLASS)
    this.#springHover(target)
  }

  dragLeave(event) {
    // dragleave also fires when the cursor moves onto a *child* of the
    // target (the folder name, the icon) — dropping the highlight there
    // makes it flicker while you're hovering dead-center on the folder.
    if (event.currentTarget.contains(event.relatedTarget)) return
    event.currentTarget.classList.remove(DROP_CLASS)
    if (this.springPendingEl === event.currentTarget) this.#cancelPendingSpring()
  }

  // ----- Spring-loading -----

  #springHover(el) {
    if (this.springPendingEl === el) return                      // pulses already running
    if (this.springs.some(s => s.owner === el)) return           // already sprung open

    this.#cancelPendingSpring()
    const action = this.#springAction(el)
    if (!action) return

    action.prefetch?.()
    this.springPendingEl = el
    el.classList.add(SPRING_CLASS)
    this.springTimer = setTimeout(() => {
      this.#cancelPendingSpring()
      const entry = action.open()
      if (entry) this.springs.push(entry)
    }, SPRING_DELAY)
  }

  // What springing this element would do — or null if nothing's behind it.
  // Sidebar branches return a {owner, keepAlive, close} entry (they revert
  // as soon as the drag leaves them); tunnels manage their own lifetime
  // (they persist until the drag ends).
  #springAction(el) {
    // Sidebar: the summary link of a collapsed <details> branch.
    if (el.classList.contains("folder-tree__link")) {
      const details = el.closest("summary")?.parentElement
      if (!details || details.open) return null
      return {
        open: () => {
          details.open = true
          return { owner: el, keepAlive: [details], close: () => { details.open = false } }
        }
      }
    }

    // Main pane: folder rows tunnel in, breadcrumbs tunnel back up — the
    // pane temporarily becomes that folder's real level view. Any folder
    // (empty included: tunnel in, drop on the empty pane to file there).
    if (el.classList.contains("folder-row") ||
        (el.classList.contains("workspace-crumbs__crumb") &&
         !el.classList.contains("workspace-crumbs__crumb--current"))) {
      const url = el.href
      if (!url) return null
      return {
        prefetch: () => this.#prefetchPane(url),
        open: () => { this.#tunnel(url); return null }
      }
    }

    return null
  }

  // ----- Tunneling (temporary in-drag navigation of the main pane) -----

  #prefetchPane(url) {
    if (this.paneCache?.url === url) return this.paneCache.promise
    const promise = fetch(url, { headers: { "Accept": "text/html" } })
      .then(response => {
        if (!response.ok) throw new Error(`prefetch ${response.status}`)
        return response.text()
      })
      .then(html => new DOMParser().parseFromString(html, "text/html"))
    // Swallow here so an abandoned prefetch never surfaces as an unhandled
    // rejection; #tunnel re-awaits the cached promise and handles failure.
    promise.catch(() => {})
    this.paneCache = { url, promise }
    return promise
  }

  async #tunnel(url) {
    let doc
    try { doc = await this.#prefetchPane(url) } catch { return }
    // The world may have moved on while the fetch ran.
    if (!this.dragActive) return
    const main = this.element.querySelector(".workspace__main")
    const incoming = doc.querySelector(".workspace__main")
    if (!main || !incoming) return

    if (!this.tunnelHome) {
      // Keep the dragged row's node in the document — removing the drag
      // source mid-drag makes browsers skip dragend entirely, leaking the
      // whole drag state. It waits out the tunnel in a hidden stash.
      if (this.dragSourceEl && main.contains(this.dragSourceEl)) {
        this.sourceHome = { parent: this.dragSourceEl.parentNode, next: this.dragSourceEl.nextSibling }
        this.#stash().appendChild(this.dragSourceEl)
      }
      this.tunnelHome = { nodes: Array.from(main.childNodes) }
      this.homeFolderId = main.dataset.folderId
    }
    main.replaceChildren(...incoming.childNodes)
    // Swap the pane's own drop identity too — dead-space drops now file
    // into the tunneled folder.
    main.dataset.folderId = incoming.dataset.folderId || ""
    this.tunnelUrl = url
    // Restart the entrance animation for each level.
    main.classList.remove("workspace__main--tunneled")
    void main.offsetWidth
    main.classList.add("workspace__main--tunneled")
  }

  #restoreTunnel() {
    if (!this.tunnelHome) return
    const main = this.element.querySelector(".workspace__main")
    if (main) {
      main.replaceChildren(...this.tunnelHome.nodes)
      main.dataset.folderId = this.homeFolderId ?? main.dataset.folderId
      main.classList.remove("workspace__main--tunneled")
    }
    if (this.dragSourceEl && this.sourceHome?.parent?.isConnected) {
      this.sourceHome.parent.insertBefore(this.dragSourceEl, this.sourceHome.next)
    }
    this.tunnelHome = null
    this.tunnelUrl = null
    this.sourceHome = null
  }

  #stash() {
    if (!this.stashEl) {
      this.stashEl = document.createElement("div")
      this.stashEl.style.display = "none"
      this.element.appendChild(this.stashEl)
    }
    return this.stashEl
  }

  #cancelPendingSpring() {
    clearTimeout(this.springTimer)
    this.springPendingEl?.classList.remove(SPRING_CLASS)
    this.springPendingEl = null
  }

  #collapseAllSprings() {
    while (this.springs.length) this.springs.pop().close()
  }

  #dragCleanup() {
    this.dragActive = false
    this.#cancelPendingSpring()
    this.paneCache = null
    // A committed drop keeps the tunneled pane and its pulsing target on
    // screen until the refresh lands (or the move fails); an abandoned
    // drag snaps everything back to where it started.
    if (!this.dropCommitted) {
      this.#collapseAllSprings()
      this.#restoreTunnel()
    }
    setTimeout(() => { this.dragHappened = false }, 0)
  }

  drop(event) {
    if (!this.#accepts(event)) return
    event.preventDefault()
    // Same innermost-target-wins rule as dragOver: a drop on a folder row
    // must not also fire the pane-wide "file here" target behind it.
    event.stopPropagation()
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
      this.#patch(payload.url, { parent_id: targetFolderId }, "Folder moved.", target)
    } else {
      let payload = {}
      try { payload = JSON.parse(event.dataTransfer.getData(PLAN_MIME)) } catch {}
      if (!payload.url) return
      // Same quiet no-op when the plan is already filed right here.
      if ((payload.folderId || "") === targetFolderId) return
      this.#patch(payload.url, { folder_id: targetFolderId }, "Plan moved.", target)
    }
  }

  #accepts(event) {
    const types = event.dataTransfer.types
    return types.includes(PLAN_MIME) || types.includes(FOLDER_MIME)
  }

  #patch(url, body, fallbackMessage, target) {
    // The PATCH + page refresh takes a beat — show it immediately: the drop
    // target pulses, the dragged row stays ghosted, the cursor says busy.
    // (drop fires before dragend, so the --dragging source is still marked.)
    this.dropCommitted = true
    target?.classList.add(BUSY_CLASS)
    this.element.classList.add("workspace--moving")
    this.element.querySelector(".plan-row--dragging, .folder-tree__link--dragging")
      ?.classList.add("dnd-source--moving")

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
          // A drop inside a tunneled folder lands you there for real —
          // Finder leaves you in the window you sprang into.
          if (this.tunnelUrl) {
            window.Turbo.visit(this.tunnelUrl, { action: "advance" })
          } else {
            window.Turbo.visit(window.location.href, { action: "replace" })
          }
        } else {
          this.#toast(message, "notice")
          this.#clearBusy(target)
        }
      })
      .catch(error => {
        this.#clearBusy(target)
        this.#toast(error.message, "alert")
      })
  }

  #clearBusy(target) {
    this.dropCommitted = false
    target?.classList.remove(BUSY_CLASS)
    this.element.classList.remove("workspace--moving")
    this.element.querySelector(".dnd-source--moving")?.classList.remove("dnd-source--moving")
    this.#collapseAllSprings()
    this.#restoreTunnel()
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
