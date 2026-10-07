import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["reviews", "discussion", "commentForm", "changeButton", "notice", "search", "reviewerId", "results", "managementError", "approval", "approvalNote", "approvalError", "approvalStatement", "approveButton", "comparison", "diff"]
  static values = { url: String, searchUrl: String }

  connect() {
    this.searchSequence = 0
    this.refreshSequence = 0
    // Shared streams carry an invalidation signal, never another viewer's
    // forms, tokens or personal task status.
    window.Turbo.StreamActions["coplan-review-changed"] ||= function () {
      document.getElementById(this.getAttribute("target"))?.dispatchEvent(new CustomEvent("coplan:reviews-changed"))
    }
    document.body.classList.toggle("has-review-tray", this.hasDiscussionTarget)
  }

  disconnect() {
    clearTimeout(this.searchTimer)
    this.searchSequence++
    this.refreshSequence++
    document.body.classList.remove("has-review-tray")
  }

  viewedRevision() {
    return document.getElementById("plan-content-body")?.getAttribute("data-coplan--live-update-revision-value")
  }

  openReviews() { this.reviewsTarget.showModal() }
  closeReviews() { this.reviewsTarget.close() }
  closeComparison() { this.comparisonTarget.close() }

  expand() {
    this.discussionTarget.hidden = false
    if (this.hasChangeButtonTarget) this.changeButtonTarget.setAttribute("aria-expanded", "true")
    this.commentFormTarget.querySelector("textarea").focus({ preventScroll: true })
  }

  collapse() {
    this.discussionTarget.hidden = true
    if (this.hasChangeButtonTarget) this.changeButtonTarget.setAttribute("aria-expanded", "false")
    this.discussionTarget.dispatchEvent(new CustomEvent("coplan:composer-close", { bubbles: true }))
    const button = this.hasChangeButtonTarget ? this.changeButtonTarget : this.element.querySelector(".review-chip")
    button?.focus({ preventScroll: true })
    if (this.reviewWithdrawn) {
      this.element.querySelector(".review-tray")?.remove()
      document.body.classList.remove("has-review-tray")
    }
  }

  escape(event) {
    if (this.reviewsTarget.open || this.approvalTarget.open || this.comparisonTarget.open) return
    if (this.hasDiscussionTarget && !this.discussionTarget.hidden) {
      event.preventDefault()
      this.collapse()
    }
  }

  requestChanges(event) {
    this.responseUrl = event.currentTarget.dataset.url
    this.expand()
  }

  confirmApproval(event) {
    this.responseUrl = event.currentTarget.dataset.url
    this.approvalRevision = this.viewedRevision()
    this.approvalErrorTarget.textContent = ""
    this.approveButtonTarget.textContent = `Approve v${this.approvalRevision}`
    this.approvalStatementTarget.textContent = `I have read v${this.approvalRevision} and agree with all of its content.`
    this.approvalTarget.showModal()
  }

  closeApproval() {
    this.approvalTarget.close()
  }

  async approve(event) {
    event.preventDefault()
    await this.withBusy(event.target, this.approvalErrorTarget, async () => {
      const result = await this.write(this.responseUrl, "POST", { review_response: { revision: this.approvalRevision, decision: "approved", note: this.approvalNoteTarget.value } })
      const synced = !result.comment_thread_id || await this.refreshThreads(result.comment_thread_id)
      this.approvalTarget.close()
      this.approvalNoteTarget.value = ""
      this.noticeTarget.textContent = `Your approval of v${this.approvalRevision} is recorded.` + (synced ? "" : " Refresh the page to see your comment.")
      await this.refresh()
    }, "Recording…")
  }

  async post(event) {
    event.preventDefault()
    const form = event.target
    const input = form.querySelector("textarea")
    if (form.closest('[data-dictation-busy="true"]') || form.querySelector('[data-dictation-busy="true"]')) return
    const error = form.querySelector('[role="alert"]')
    await this.withBusy(form, error, async () => {
      const result = await this.write(this.responseUrl, "POST", { review_response: { revision: this.viewedRevision(), decision: "changes_requested", note: input.value } })
      // Feedback lives in the ordinary discussion collection.
      const synced = await this.refreshThreads(result.comment_thread_id)
      this.noticeTarget.textContent = "Changes requested. Your feedback is in the plan’s comments." + (synced ? "" : " Refresh the page to see your comment.")
      input.value = ""
      this.collapse()
      await this.refresh()
    }, "Posting…")
  }

  async refreshThreads(threadId) {
    const editor = document.querySelector('[data-coplan--inline-editor-comments-url-value]')
    if (!editor) return false
    try {
      const response = await fetch(editor.getAttribute("data-coplan--inline-editor-comments-url-value"), { credentials: "same-origin", headers: { Accept: "text/html" } })
      if (response.ok) {
        const incoming = new DOMParser().parseFromString(await response.text(), "text/html")
        const id = `comment_thread_${threadId}`
        const thread = incoming.getElementById(id)
        if (thread && !document.getElementById(id)) document.getElementById("plan-threads")?.append(thread)
        for (const id of ["plan-general-comments", "plan-detached-comments"]) {
          const from = incoming.getElementById(id), to = document.getElementById(id)
          if (from && to) to.replaceWith(from)
        }
        return true
      }
    } catch { /* The response was saved; a refresh failure must not claim otherwise. */ }
    // The thread stays in the existing collection, available via its
    // normal discussion link. Posting doesn't force the reader into it.
    return false
  }

  async refresh() {
    const sequence = ++this.refreshSequence
    try {
      const response = await fetch(this.urlValue, { credentials: "same-origin", headers: { Accept: "text/html" } })
      if (!response.ok) return
      const incoming = new DOMParser().parseFromString(await response.text(), "text/html")
      if (sequence !== this.refreshSequence || !this.element.isConnected) return
      const tray = incoming.querySelector(".review-tray")
      const existingTray = this.element.querySelector(".review-tray")
      const wasWithdrawn = this.reviewWithdrawn
      this.reviewWithdrawn = !tray
      if (!tray && existingTray) {
        if (this.discussionTarget.hidden) {
          existingTray.remove()
          document.body.classList.remove("has-review-tray")
        } else {
          existingTray.querySelector("[data-review-status]").textContent = "Your review request is no longer active."
          existingTray.querySelector("[data-review-decision-actions]").replaceChildren()
          this.commentFormTarget.querySelector('[type="submit"]').disabled = true
          this.commentFormTarget.querySelector('[role="alert"]').textContent = "This review request is no longer active. Your unsent feedback is still here."
        }
      }
      if (tray && !this.element.querySelector(".review-tray")) {
        this.element.append(tray)
        document.body.classList.add("has-review-tray")
      }
      if (tray && wasWithdrawn && this.hasCommentFormTarget) {
        this.commentFormTarget.querySelector('[type="submit"]').disabled = false
        this.commentFormTarget.querySelector('[role="alert"]').textContent = ""
      }
      // Preserve the tray, its open state, dictation and all unsent text.
      for (const selector of ["[data-review-status]", "[data-review-decision-actions]", "[data-review-chip-label]", "[data-review-assignments]", "[data-review-history]"]) {
        const from = incoming.querySelector(selector), to = this.element.querySelector(selector)
        if (from && to) to.replaceChildren(...from.childNodes)
      }
      if (this.hasChangeButtonTarget) this.changeButtonTarget.setAttribute("aria-expanded", String(!this.discussionTarget.hidden))
    } catch { /* The task and draft remain usable; the next event retries. */ }
  }

  async assign(event) {
    event.preventDefault()
    if (!this.reviewerIdTarget.value) { this.managementErrorTarget.textContent = "Choose a person from the results first."; return }
    await this.withBusy(event.target, this.managementErrorTarget, async () => {
      await this.write(this.urlValue, "POST", { review_request: { reviewer_id: this.reviewerIdTarget.value, requirement: event.target.querySelector("select").value } })
      this.searchTarget.value = ""; this.reviewerIdTarget.value = ""; this.resultsTarget.replaceChildren()
      await this.refresh()
    }, "Requesting…")
  }

  search() {
    clearTimeout(this.searchTimer)
    this.reviewerIdTarget.value = ""
    const query = this.searchTarget.value.trim(), sequence = ++this.searchSequence
    this.resultsTarget.replaceChildren()
    if (!query) return
    this.searchTimer = setTimeout(async () => {
      try {
        const response = await fetch(`${this.searchUrlValue}?q=${encodeURIComponent(query)}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
        if (!response.ok) throw new Error("Search unavailable")
        const users = await response.json()
        if (sequence !== this.searchSequence || !this.element.isConnected) return
        for (const user of users) {
          const button = document.createElement("button")
          button.type = "button"; button.className = "review-search-result"
          button.textContent = [user.name, user.username && `@${user.username}`, user.team].filter(Boolean).join(" · ")
          button.dataset.action = "coplan--review-tray#chooseReviewer"
          button.dataset.userId = user.id; button.dataset.userName = user.name
          this.resultsTarget.append(button)
        }
        if (!users.length) this.resultsTarget.textContent = "No people found."
      } catch { if (sequence === this.searchSequence) this.resultsTarget.textContent = "Search unavailable. Please try again." }
    }, 150)
  }

  chooseReviewer(event) {
    this.searchSequence++
    this.reviewerIdTarget.value = event.currentTarget.dataset.userId
    this.searchTarget.value = event.currentTarget.dataset.userName
    this.resultsTarget.replaceChildren()
  }

  requestAgain(event) { this.manage(event, "PATCH", { review_request: { request_again: true } }) }
  changeRequirement(event) { this.manage(event, "PATCH", { review_request: { requirement: event.currentTarget.dataset.requirement } }) }
  withdraw(event) { this.manage(event, "DELETE") }

  async manage(event, method, body) {
    await this.withBusy(event.currentTarget, this.managementErrorTarget, async () => {
      await this.write(event.currentTarget.dataset.url, method, body)
      await this.refresh()
    }, "Updating…")
  }

  async compare(event) {
    this.diffTarget.textContent = "Loading changes…"
    this.comparisonTarget.showModal()
    try {
      const response = await fetch(event.currentTarget.dataset.url, { credentials: "same-origin", headers: { Accept: "text/html" } })
      if (!response.ok) throw new Error("Couldn't load the comparison. Please try again.")
      this.diffTarget.innerHTML = await response.text()
    } catch (error) { this.diffTarget.textContent = error.message }
  }

  openThread(event) {
    this.closeReviews()
    document.dispatchEvent(new CustomEvent("coplan:open-thread", { detail: { threadId: event.currentTarget.dataset.threadId } }))
  }

  csrfToken() { return document.querySelector('meta[name="csrf-token"]')?.content || "" }

  async write(url, method, body) {
    let response
    try {
      response = await fetch(url, { method, headers: { "X-CSRF-Token": this.csrfToken(), "Content-Type": "application/json", Accept: "application/json" }, credentials: "same-origin", body: body ? JSON.stringify(body) : undefined })
    } catch {
      throw new Error("Couldn't reach CoPlan. Your draft is still here. Check that the server is running and try again.")
    }
    if (response.status === 204) return {}
    let result
    try { result = await response.json() } catch { throw new Error("Couldn't save your response. Your draft is still here. Please try again.") }
    if (!response.ok) throw new Error(result.error || "Couldn't save. Please try again.")
    return result
  }

  async withBusy(container, errorTarget, action, label) {
    if (container.getAttribute("aria-busy") === "true") return
    const buttons = container.matches("button") ? [container] : [...container.querySelectorAll('[type="submit"]')]
    const saved = buttons.map(button => ({ button, html: button.innerHTML, disabled: button.disabled }))
    errorTarget.textContent = ""
    container.setAttribute("aria-busy", "true")
    buttons.forEach(button => { button.disabled = true; button.textContent = label })
    try { await action() } catch (error) { errorTarget.textContent = error.message }
    finally { container.removeAttribute("aria-busy"); saved.forEach(({ button, html, disabled }) => { button.innerHTML = html; button.disabled = disabled }) }
  }
}
