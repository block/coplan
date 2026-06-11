import { Controller } from "@hotwired/stimulus"

// Gates viewer-specific thread actions (Accept/Discard/Reopen) on the client.
//
// Turbo Stream broadcasts re-render thread partials for *every* subscriber with
// no server-side current_user, so the server can't decide which viewer-specific
// actions to show. Those actions are therefore rendered unconditionally and
// hidden by default via CSS; this controller compares the viewer's id (known on
// the client) against each thread's author / plan-author ids and reveals only
// the actions the viewer is actually allowed to take.
export default class extends Controller {
  static values = { viewerId: String }

  connect() {
    this.apply()
    // Reapply when threads are appended or replaced by a broadcast.
    this._observer = new MutationObserver(() => this.apply())
    this._observer.observe(this.element, { childList: true })
  }

  disconnect() {
    if (this._observer) {
      this._observer.disconnect()
      this._observer = null
    }
  }

  apply() {
    const viewerId = this.viewerIdValue
    this.element.querySelectorAll("[data-plan-author-id]").forEach((thread) => {
      const isPlanAuthor = viewerId !== "" && thread.dataset.planAuthorId === viewerId
      const isThreadAuthor = viewerId !== "" && thread.dataset.threadAuthorId === viewerId
      thread.classList.toggle("viewer-is-plan-author", isPlanAuthor)
      thread.classList.toggle("viewer-is-thread-author", isThreadAuthor)
    })
  }
}
