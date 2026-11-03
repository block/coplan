import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["comment", "disclosure", "filter", "count", "empty"]

  initialize() {
    this.highlightedThreadIds = new Set()
  }

  connect() {
    this.key = `coplan-comments:${window.location.pathname}`
    try { this.filterTarget.value = sessionStorage.getItem(this.key) || "open" } catch { /* Keep the default. */ }
    // The highlighter may have connected before this controller. Request its
    // current snapshot as well as listening for subsequent anchor updates.
    this.element.dispatchEvent(new CustomEvent("coplan:request-text-anchors", { bubbles: true }))
    this.applyFilter()
  }

  commentTargetConnected() { this.scheduleFilter() }
  commentTargetDisconnected() { this.scheduleFilter() }

  scheduleFilter() {
    if (this.filterScheduled) return
    this.filterScheduled = true
    queueMicrotask(() => {
      this.filterScheduled = false
      if (this.element.isConnected) this.applyFilter()
    })
  }

  anchorsUpdated(event) {
    // Source diagrams and the editor also emit this event without text-anchor
    // state. Only the text highlighter owns this snapshot.
    if (!event.detail?.highlightedThreadIds) return
    this.highlightedThreadIds = new Set(event.detail.highlightedThreadIds)
    this.applyFilter()
  }

  filterChanged() {
    try { sessionStorage.setItem(this.key, this.filterTarget.value) } catch { /* Keep the local choice. */ }
    this.applyFilter()
  }

  applyFilter() {
    if (!this.hasFilterTarget || !this.hasCountTarget || !this.hasEmptyTarget) return
    const filter = this.filterTarget.value || "open"
    // Keep a document entry whenever the renderer cannot place a text anchor.
    const comments = this.commentTargets.filter(comment => {
      const inline = comment.dataset.inlineAnchor === "true" &&
        this.highlightedThreadIds.has(comment.dataset.threadId)
      if (inline) comment.hidden = true
      return !inline
    })
    comments.forEach(comment => { comment.hidden = filter !== "all" && comment.dataset.commentStatus !== filter })
    this.element.dispatchEvent(new CustomEvent("coplan:document-comment-count", {
      bubbles: true, detail: { count: comments.length }
    }))
    const visible = comments.filter(comment => !comment.hidden).length
    this.countTarget.textContent = visible || ""
    this.emptyTarget.textContent = filter === "all" ? "No comments yet." : `No ${filter} discussions.`
    this.emptyTarget.hidden = visible > 0 || filter === "open"
  }

  revealThread(event) {
    const comment = this.commentTargets.find(comment => comment.dataset.threadId === event.detail.threadId)
    if (!comment || !comment.hidden) return
    this.filterTarget.value = comment.dataset.commentStatus
    this.filterChanged()
  }

  posted(event) {
    if (!event.detail.success) return
    this.filterTarget.value = "open"
    this.filterChanged()
    this.disclosureTarget.open = true
  }
}
