import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["reviews", "discussion", "commentForm", "changeButton", "notice", "search", "reviewerId", "results", "assignment", "addReviewerButton", "assignButton", "managementError", "managementStatus", "assignmentError", "approval", "approvalNote", "approvalError", "approvalTitle", "approveButton", "comparison", "diff", "activity", "suggestions"]
  static values = { url: String, searchUrl: String, suggestionsUrl: String }

  connect() {
    this.searchSequence = 0
    this.suggestionSequence = 0
    this.refreshSequence = 0
    // Shared streams carry an invalidation signal, never another viewer's
    // forms, tokens or personal task status.
    window.Turbo.StreamActions["coplan-review-changed"] ||= function () {
      document.getElementById(this.getAttribute("target"))?.dispatchEvent(new CustomEvent("coplan:reviews-changed"))
    }
    const tray = this.element.querySelector(".review-tray")
    if (tray) tray.showPopover()
    document.body.classList.toggle("has-review-tray", !!tray?.matches(":popover-open"))
    this.syncFeedbackLinks()
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
  closeReviews() { this.closeAssignment(); this.reviewsTarget.close() }
  closeComparison() { this.comparisonTarget.close() }
  openActivity() { this.activityTarget.showModal() }
  closeActivity() { this.activityTarget.close() }

  positionAssignment() {
    if (!this.hasAssignmentTarget || !this.assignmentTarget.matches(":popover-open")) return
    const trigger = this.addReviewerButtonTarget.getBoundingClientRect()
    const panel = this.assignmentTarget
    panel.style.left = `${Math.max(8, Math.min(trigger.right - panel.offsetWidth, window.innerWidth - panel.offsetWidth - 8))}px`
    // Leave room beneath the field for an overlay of search results.
    panel.style.top = `${Math.max(8, Math.min(trigger.bottom + 8, window.innerHeight - Math.max(panel.offsetHeight, 330) - 8))}px`
    this.resultsTarget.style.maxHeight = `${Math.max(60, Math.min(210, window.innerHeight - this.searchTarget.getBoundingClientRect().bottom - 16))}px`
  }

  assignmentToggled() {
    const open = this.assignmentTarget.matches(":popover-open")
    this.addReviewerButtonTarget.setAttribute("aria-expanded", String(open))
    if (open) {
      this.positionAssignment()
      this.assignButtonTarget.disabled = !this.reviewerIdTarget.value
      this.searchTarget.focus({ preventScroll: true })
      this.loadSuggestions()
    } else this.closeAssignment()
  }

  dismissAssignment(event) {
    event.preventDefault()
    event.stopPropagation()
    this.closeAssignment()
    this.addReviewerButtonTarget.focus({ preventScroll: true })
  }

  closeAssignment() {
    if (!this.hasAssignmentTarget) return
    this.assignmentTarget.hidePopover()
    this.addReviewerButtonTarget.setAttribute("aria-expanded", "false")
    this.hideResults()
    clearTimeout(this.searchTimer)
    this.searchSequence++
  }

  hideResults() {
    this.resultsTarget.hidden = true
    this.searchTarget.setAttribute("aria-expanded", "false")
  }

  focusResults(event) {
    const first = !this.resultsTarget.hidden && this.resultsTarget.querySelector("button:not(:disabled)")
    if (first) { event.preventDefault(); first.focus({ preventScroll: true }) }
  }

  reconsider() {
    const tray = this.element.querySelector(".review-tray")
    tray.showPopover()
    document.body.classList.add("has-review-tray")
    tray.dataset.reconsidering = "true"
    this.changeButtonTarget.focus({ preventScroll: true })
  }

  expand() {
    this.element.querySelector(".review-tray").dataset.composing = "true"
    this.discussionTarget.hidden = false
    if (this.hasChangeButtonTarget) this.changeButtonTarget.setAttribute("aria-expanded", "true")
    this.commentFormTarget.querySelector("textarea").focus({ preventScroll: true })
  }

  collapse() {
    this.changesRevision = null
    const tray = this.element.querySelector(".review-tray")
    delete tray.dataset.composing
    delete tray.dataset.reconsidering
    this.discussionTarget.hidden = true
    if (this.hasChangeButtonTarget) this.changeButtonTarget.setAttribute("aria-expanded", "false")
    this.discussionTarget.dispatchEvent(new CustomEvent("coplan:composer-close", { bubbles: true }))
    const reconsider = tray.querySelector(".review-reconsider")
    const button = reconsider || (this.hasChangeButtonTarget ? this.changeButtonTarget : this.element.querySelector('.review-log-panel__header button'))
    button?.focus({ preventScroll: true })
    if (this.reviewWithdrawn) {
      this.element.querySelector(".review-tray")?.remove()
      document.body.classList.remove("has-review-tray")
    }
  }

  escape(event) {
    if (this.reviewsTarget.open || this.approvalTarget.open || this.comparisonTarget.open || this.activityTarget.open) return
    if (this.hasDiscussionTarget && !this.discussionTarget.hidden) {
      event.preventDefault()
      this.collapse()
    }
  }

  requestChanges(event) {
    this.responseUrl = event.currentTarget.dataset.url
    if (this.discussionTarget.hidden) this.changesRevision = this.viewedRevision()
    this.expand()
  }

  confirmApproval(event) {
    this.responseUrl = event.currentTarget.dataset.url
    this.approvalRevision = this.viewedRevision()
    this.approvalErrorTarget.textContent = ""
    this.approveButtonTarget.textContent = `Approve v${this.approvalRevision}`
    this.approvalTitleTarget.textContent = `Approve v${this.approvalRevision}?`
    this.approvalTarget.showModal()
  }

  closeApproval() {
    this.approvalTarget.close()
  }

  responseIntent(url, revision, decision, note) {
    this.responseIntents ||= {}
    const fields = JSON.stringify([url, String(revision), note.trim()])
    const previous = this.responseIntents[decision]
    if (previous?.fields === fields) return previous
    return this.responseIntents[decision] = { fields, key: crypto.randomUUID() }
  }

  confirmIntent(decision, intent) {
    if (this.responseIntents[decision] === intent) delete this.responseIntents[decision]
  }

  async approve(event) {
    event.preventDefault()
    await this.withBusy(event.target, this.approvalErrorTarget, async () => {
      const intent = this.responseIntent(this.responseUrl, this.approvalRevision, "approved", this.approvalNoteTarget.value)
      const result = await this.write(this.responseUrl, "POST", { review_response: { revision: this.approvalRevision, decision: "approved", note: this.approvalNoteTarget.value, idempotency_key: intent.key } })
      this.confirmIntent("approved", intent)
      const synced = !result.comment_thread_id || await this.refreshThreads(result.comment_thread_id)
      this.approvalTarget.close()
      this.approvalNoteTarget.value = ""
      if (this.hasNoticeTarget) this.noticeTarget.textContent = `Your approval of v${this.approvalRevision} is recorded.` + (synced ? "" : " Refresh the page to see your comment.")
      const tray = this.element.querySelector(".review-tray")
      if (tray) delete tray.dataset.reconsidering
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
      const intent = this.responseIntent(form.action, this.changesRevision, "changes_requested", input.value)
      const result = await this.write(form.action, "POST", { review_response: { revision: this.changesRevision, decision: "changes_requested", note: input.value, idempotency_key: intent.key } })
      this.confirmIntent("changes_requested", intent)
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
        for (const id of ["plan-general-comment-list", "plan-detached-comments"]) {
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
      if (tray && existingTray) existingTray.dataset.completed = tray.dataset.completed
      if (tray && !this.element.querySelector(".review-tray")) this.element.append(tray)
      const currentTray = this.element.querySelector(".review-tray")
      if (tray && currentTray) {
        currentTray.showPopover()
        document.body.classList.add("has-review-tray")
      }
      if (tray && wasWithdrawn && this.hasCommentFormTarget) {
        this.commentFormTarget.querySelector('[type="submit"]').disabled = false
        this.commentFormTarget.querySelector('[role="alert"]').textContent = ""
      }
      const table = this.element.querySelector(".review-table-scroll")
      const tableScroll = table && { top: table.scrollTop, left: table.scrollLeft }
      // Preserve the tray, its open state, dictation and all unsent text.
      for (const selector of ["[data-review-status]", "[data-review-decision-actions]", "[data-review-summary]", "[data-review-log-summary]", "[data-review-assignments]", "[data-review-roster]", "[data-review-history]"]) {
        const from = incoming.querySelector(selector), to = this.element.querySelector(selector)
        if (from && to) {
          to.replaceChildren(...from.childNodes)
          if (from.hasAttribute("data-recorded")) to.dataset.recorded = from.dataset.recorded
        }
      }
      const refreshedTable = this.element.querySelector(".review-table-scroll")
      if (tableScroll && refreshedTable) { refreshedTable.scrollTop = tableScroll.top; refreshedTable.scrollLeft = tableScroll.left }
      const navCount = document.getElementById("nav-approvals-count")
      if (navCount) navCount.textContent = Number(incoming.getElementById("plan-review-controls")?.dataset.reviewRecordCount) || ""
      if (this.hasChangeButtonTarget) this.changeButtonTarget.setAttribute("aria-expanded", String(!this.discussionTarget.hidden))
      this.syncFeedbackLinks()
    } catch { /* The task and draft remain usable; the next event retries. */ }
  }

  async assign(event) {
    event.preventDefault()
    if (!this.reviewerIdTarget.value) { this.assignmentErrorTarget.textContent = "Choose a person from the results first."; return }
    await this.withBusy(event.target, this.assignmentErrorTarget, async () => {
      await this.write(this.urlValue, "POST", { review_request: { reviewer_id: this.reviewerIdTarget.value, requirement: event.target.querySelector('[type="checkbox"]').checked ? "required" : "optional", replace_withdrawn: true } })
      this.searchTarget.value = ""; this.reviewerIdTarget.value = ""; this.resultsTarget.replaceChildren()
      this.closeAssignment()
      event.target.querySelector('[type="checkbox"]').checked = true
      this.addReviewerButtonTarget.focus({ preventScroll: true })
      await this.refresh()
    }, "Requesting…")
    this.assignButtonTarget.disabled = !this.reviewerIdTarget.value
  }

  search() {
    clearTimeout(this.searchTimer)
    this.reviewerIdTarget.value = ""
    this.assignButtonTarget.disabled = true
    const query = this.searchTarget.value.trim(), sequence = ++this.searchSequence
    this.resultsTarget.replaceChildren()
    this.assignmentErrorTarget.textContent = ""
    if (!query) { this.hideResults(); return }
    this.resultsTarget.hidden = false
    this.searchTarget.setAttribute("aria-expanded", "true")
    this.resultsTarget.textContent = "Searching…"
    this.searchTimer = setTimeout(async () => {
      try {
        const response = await fetch(`${this.searchUrlValue}?q=${encodeURIComponent(query)}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
        if (!response.ok) throw new Error("Search unavailable")
        const users = await response.json()
        if (sequence !== this.searchSequence || !this.element.isConnected) return
        this.resultsTarget.replaceChildren()
        for (const user of users) {
          this.resultsTarget.append(this.personButton(user, [user.username && `@${user.username}`, user.team].filter(Boolean).join(" · ")))
        }
        if (!users.length) this.resultsTarget.textContent = "No people found."
      } catch { if (sequence === this.searchSequence) this.resultsTarget.textContent = "Search unavailable. Please try again." }
    }, 150)
  }

  personButton(user, detailText) {
    const button = document.createElement("button")
    button.type = "button"; button.className = "review-search-result"
    const avatar = document.createElement("span")
    avatar.className = "review-search-result__avatar"
    avatar.textContent = user.name.split(/\s+/).filter(Boolean).slice(0, 2).map(part => part[0]).join("").toUpperCase()
    avatar.setAttribute("aria-hidden", "true")
    const info = document.createElement("span"), name = document.createElement("strong"), detail = document.createElement("small")
    name.textContent = user.name
    const assigned = [...this.element.querySelectorAll('[data-reviewer-id]')].some(row => row.dataset.reviewerId === user.id)
    detail.textContent = assigned ? "Already a reviewer" : detailText
    button.disabled = assigned
    info.append(name, detail); button.append(avatar, info)
    button.dataset.action = "coplan--review-tray#chooseReviewer"
    button.dataset.userId = user.id; button.dataset.userName = user.name
    return button
  }

  async loadSuggestions() {
    if (!this.hasSuggestionsTarget) return
    const list = this.suggestionsTarget.querySelector("[data-review-suggestion-list]"), sequence = ++this.suggestionSequence
    try {
      const response = await fetch(this.suggestionsUrlValue, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!response.ok) throw new Error("Suggestions unavailable")
      const suggestions = await response.json()
      if (sequence !== this.suggestionSequence || !this.element.isConnected) return
      list.replaceChildren(...suggestions.map(({ reviewer, reason, requirement }) => {
        const button = this.personButton(reviewer, [reason, requirement === "optional" && "Optional"].filter(Boolean).join(" · "))
        button.dataset.requirement = requirement
        return button
      }))
      this.suggestionsTarget.hidden = !suggestions.length
    } catch { if (sequence === this.suggestionSequence) this.suggestionsTarget.hidden = true }
    this.positionAssignment()
  }

  chooseReviewer(event) {
    this.searchSequence++
    this.reviewerIdTarget.value = event.currentTarget.dataset.userId
    this.searchTarget.value = event.currentTarget.dataset.userName
    if (event.currentTarget.dataset.requirement) {
      this.assignmentTarget.querySelector('[type="checkbox"]').checked = event.currentTarget.dataset.requirement === "required"
    }
    this.assignButtonTarget.disabled = false
    this.resultsTarget.replaceChildren()
    this.hideResults()
    this.searchTarget.focus({ preventScroll: true })
  }

  requestAgain(event) { this.manage(event, "PATCH", { review_request: { request_again: true } }) }
  changeRequirement(event) { this.manage(event, "PATCH", { review_request: { requirement: event.currentTarget.dataset.requirement } }) }
  withdraw(event) { this.manage(event, "DELETE", { review_request: { remove: true } }) }

  async manage(event, method, body) {
    if (this.managing) return
    const button = event.currentTarget
    const reviewerId = button.closest("[data-reviewer-id]").dataset.reviewerId
    const roster = this.element.querySelector("[data-review-assignments]")
    const add = this.hasAddReviewerButtonTarget ? this.addReviewerButtonTarget : null
    const wasDisabled = add?.disabled
    this.managing = true
    this.reviewsTarget.setAttribute("data-managing", "")
    this.managementStatusTarget.textContent = "Updating…"
    roster.inert = true
    roster.setAttribute("aria-busy", "true")
    if (add) add.disabled = true
    try {
      await this.withBusy(button, this.managementErrorTarget, async () => {
        await this.write(button.dataset.url, method, body)
        await this.refresh()
      }, "Updating…")
    } finally {
      this.managing = false
      this.reviewsTarget.removeAttribute("data-managing")
      this.managementStatusTarget.textContent = ""
      roster.inert = false
      roster.removeAttribute("aria-busy")
      if (add) add.disabled = wasDisabled
      if (this.reviewsTarget.open && [document.body, this.reviewsTarget].includes(document.activeElement)) {
        const trigger = roster.querySelector(`[data-reviewer-id="${CSS.escape(reviewerId)}"] .review-person__menu-button`) || add
        trigger?.focus({ preventScroll: true })
      }
    }
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

  syncFeedbackLinks() {
    // Thread removal already updates the document through Turbo. Keep both
    // review surfaces consistent without waiting for another review response.
    this.feedbackThreadsSeen ||= new Set()
    this.element.querySelectorAll("button[data-thread-id]").forEach(button => {
      const id = button.dataset.threadId
      if (document.getElementById(`comment_thread_${id}`)) this.feedbackThreadsSeen.add(id)
      // New thread data may still be arriving on another Turbo stream.
      else if (this.feedbackThreadsSeen.has(id)) button.remove()
    })
  }

  openThread(event) {
    this.closeReviews()
    this.closeActivity()
    const tray = this.element.querySelector(".review-tray")
    if (tray) delete tray.dataset.reconsidering
    document.dispatchEvent(new CustomEvent("coplan:open-thread", { detail: { threadId: event.currentTarget.dataset.threadId, focusReply: true } }))
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
    if (!response.ok) {
      const error = new Error(result.error || "Couldn't save. Please try again.")
      if (result.code === "authentication_required") error.signInPath = result.sign_in_path
      throw error
    }
    return result
  }

  async withBusy(container, errorTarget, action, label) {
    if (container.getAttribute("aria-busy") === "true") return
    const buttons = container.matches("button") ? [container] : [...container.querySelectorAll('[type="submit"]')]
    const saved = buttons.map(button => ({ button, html: button.innerHTML, disabled: button.disabled }))
    errorTarget.textContent = ""
    container.setAttribute("aria-busy", "true")
    buttons.forEach(button => { button.disabled = true; button.textContent = label })
    try { await action() } catch (error) {
      errorTarget.textContent = error.message
      if (error.signInPath) {
        const link = document.createElement("a")
        link.href = error.signInPath; link.target = "_blank"; link.rel = "noopener"
        link.textContent = "Sign in in a new tab"
        errorTarget.append(" ", link)
      }
    }
    finally { container.removeAttribute("aria-busy"); saved.forEach(({ button, html, disabled }) => { button.innerHTML = html; button.disabled = disabled }) }
  }
}
