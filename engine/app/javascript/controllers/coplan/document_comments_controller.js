import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "filter", "count", "empty"]

  connect() {
    this.key = `coplan-comments:${window.location.pathname}`
    try { this.filterTarget.value = sessionStorage.getItem(this.key) || "open" } catch { /* Keep the default. */ }
    this.applyFilter()
  }

  listTargetConnected() { if (this.hasFilterTarget && this.hasEmptyTarget) this.applyFilter() }

  filterChanged() {
    try { sessionStorage.setItem(this.key, this.filterTarget.value) } catch { /* Keep the local choice. */ }
    this.applyFilter()
  }

  applyFilter() {
    if (!this.hasListTarget) return
    const filter = this.filterTarget.value || "open"
    const comments = [...this.listTarget.querySelectorAll("[data-comment-status]")]
    comments.forEach(comment => { comment.hidden = filter !== "all" && comment.dataset.commentStatus !== filter })
    const navCount = document.getElementById("nav-comments-count")
    if (navCount) navCount.textContent = comments.length || ""
    const visible = comments.filter(comment => !comment.hidden).length
    this.countTarget.textContent = visible || ""
    this.emptyTarget.textContent = filter === "all" ? "No comments yet." : `No ${filter} discussions.`
    this.emptyTarget.hidden = visible > 0 || filter === "open"
  }

  revealThread(event) {
    const comment = this.listTarget.querySelector(`[data-thread-id="${event.detail.threadId}"]`)
    if (!comment || !comment.hidden) return
    this.filterTarget.value = comment.dataset.commentStatus
    this.filterChanged()
  }

  posted(event) {
    if (!event.detail.success) return
    const input = event.target.querySelector("textarea")
    input.value = ""
    input.dispatchEvent(new Event("input", { bubbles: true }))
    this.filterTarget.value = "open"
    this.filterChanged()
    input.focus({ preventScroll: true })
  }
}
