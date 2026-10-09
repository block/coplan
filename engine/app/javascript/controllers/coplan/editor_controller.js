import { Controller } from "@hotwired/stimulus"
import { commandFor } from "coplan/shortcuts"

// One network operation at a time. Every response is reconciled with both the
// sent snapshot and edits typed while it was in flight. Nothing clears a draft
// until the server has acknowledged that exact content.
export default class extends Controller {
  static targets = ["textarea", "surface", "status", "statusText", "statusAnnouncement", "back", "rawSurface", "toolbar", "formatControls", "moreTools", "newLanguage", "codePicker", "codeOption", "draftNotice", "legacyDraftNotice", "conflict", "error", "retry", "review", "replace", "latest", "style", "subscription"]
  static values = { planId: String, userId: String, draftScope: String, revision: Number, stateUrl: String, previewUrl: String, leaseUrl: String, inline: Boolean }

  async connect() {
    this.active = true
    this.inlineVisible = !this.inlineValue
    this.base = { ...this.snapshot(), revision: this.revisionValue }
    this.token = crypto.randomUUID()
    this.creationKey = crypto.randomUUID()
    this.restoreDraft(this.discardDraftOnReload())
    // Turbo owns subscribing/unsubscribing as its element enters/leaves the DOM.
    // Catch up on connection, including revisions committed while disconnected.
    this.subscriptionObserver = new MutationObserver(records => {
      if (records.some(record => record.target.hasAttribute("connected"))) this.refresh()
    })
    this.subscriptionObserver.observe(this.subscriptionTarget, { subtree: true, attributes: true, attributeFilter: ["connected"] })
    try {
      const [rich, merge] = await Promise.all([import("coplan/rich_document"), import("coplan/merge_text")])
      if (!this.active) return
      this.merge = merge
      this.richModule = rich
      this.mode = "rich"
      this.richEditor = rich.createRichDocument(this.surfaceTarget, this.textareaTarget.value,
        content => this.editorChanged("rich", content), state => this.updateToolbar(state), source => this.preview(source),
        this.inlineValue ? this.comments() : [])
      if (this.inlineValue) {
        const threads = document.getElementById("plan-threads")
        if (threads) {
          this.commentsObserver = new MutationObserver(() => {
            this.richEditor?.updateComments(this.comments())
            this.element.dispatchEvent(new CustomEvent("coplan:anchors-updated", { bubbles: true }))
          })
          this.commentsObserver.observe(threads, { childList: true })
        }
      }
      this.editor = this.richEditor
      this.updateToolbar(this.editor.toolbarState())
      if (this.inlineValue && this.hasMoreToolsTarget) {
        this.toolResizeObserver = new ResizeObserver(() => this.updateToolOverflow())
        this.toolResizeObserver.observe(this.toolbarTarget)
        this.toolResizeObserver.observe(this.formatControlsTarget)
        requestAnimationFrame(() => this.updateToolOverflow())
      }
      // Fresh inline drafts open as the document itself. A recovered draft
      // restores the mode in which the author was working.
      if (!this.inlineValue || !this.isNew || this.recoveredDraft) {
        try { this.setMode(sessionStorage.getItem(`coplan-editor-mode-${this.userIdValue}`) || "rich") } catch {}
      }
      if (!this.blocked) this.setStatus(this.dirty() ? "Recovered draft · waiting to sync" : this.isNew ? "Start writing to create this plan" : `All changes saved · v${this.base.revision}`)
      // Retire leases from the previous prototype, without acquiring one.
      if (this.leaseUrlValue) await this.request(this.leaseUrlValue, "DELETE", {}).catch(() => {})
      if (!this.active) return
      if (!this.isNew) {
        await this.refresh()
        if (!this.active) return
        this.poll = setInterval(() => { if (!document.hidden) this.refresh() }, 2500)
        if (this.dirty()) this.scheduleSave()
      }
      if (this.inlineValue) this.element.dispatchEvent(new CustomEvent("coplan:editor-ready", { bubbles: true, detail: { controller: this } }))
    } catch (error) {
      this.fail(error.message || "The editor could not load. Reload to retry.")
      if (this.inlineValue) this.element.dispatchEvent(new CustomEvent("coplan:editor-error", { bubbles: true, detail: { error } }))
    }
  }

  disconnect() {
    this.active = false
    this.subscriptionObserver?.disconnect()
    this.commentsObserver?.disconnect()
    this.toolResizeObserver?.disconnect()
    clearInterval(this.poll)
    clearTimeout(this.saveTimer)
    clearTimeout(this.refreshTimer)
    clearTimeout(this.compositionTimer)
    this.persistDraft()
    this.richEditor?.destroy()
    this.rawEditor?.destroy()
    this.releaseIdle()
    this.releaseComposition()
  }

  get isNew() { return this.planIdValue === "new" }
  snapshot() {
    return { content: this.textareaTarget.value, title: this.element.querySelector('[name="plan[title]"]').value,
      tags: this.element.querySelector('[name="plan[tag_names]"]').value }
  }
  dirty() { return JSON.stringify(this.snapshot()) !== JSON.stringify({ content: this.base.content, title: this.base.title, tags: this.base.tags }) }
  setStatus(message, state = "idle") {
    if (!this.active) return
    // Typing during a request must not hide its spinner or an unresolved error.
    if (state === "dirty") {
      if (["saving", "error", "conflict"].includes(this.statusTarget.dataset.state)) return
      state = this.dirty() ? "queued" : "idle"
      if (message === "Unsaved changes") message = state === "queued" ? (this.inlineValue ? "Changes ready to save" : "Saving soon…") : `All changes saved · v${this.base.revision}`
    }
    if (this.statusTextTarget.textContent !== message) this.statusTextTarget.textContent = message
    if (this.hasStatusAnnouncementTarget && this.statusAnnouncementTarget.textContent !== message) this.statusAnnouncementTarget.textContent = message
    this.statusTarget.dataset.state = state
    this.statusTarget.title = state === "saved" ? `${message} · ${new Date().toLocaleTimeString()}` : message
    if (this.inlineValue) {
      const close = this.statusTarget.closest(".document-editor__close-inline")
      close.dataset.state = state === "saved" ? "idle" : state
      close.disabled = ["loading", "saving"].includes(state)
      close.setAttribute("aria-label", { loading: "Opening document", queued: "Done editing and save changes", saving: "Saving document", error: this.retryable ? "Retry sync" : message, conflict: "Conflict — reload document" }[state] || "Done editing")
      close.title = ["error", "conflict", "loading", "saving"].includes(state) ? message : `Done editing · ${message}`
    }
  }

  async request(url, method = "GET", body) {
    const abort = new AbortController(), timer = setTimeout(() => abort.abort(), 15000)
    try {
      const response = await fetch(url, { method, signal: abort.signal, cache: "no-store",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
      if (!response.headers.get("content-type")?.includes("application/json")) throw new Error("Could not sync. Check your connection or sign in again; your draft is retained.")
      const data = await response.json()
      if (!response.ok) throw Object.assign(new Error(data.error || "Could not save"), data, { status: response.status })
      return data
    } catch (error) {
      if (error.name === "AbortError") throw new Error("The request timed out. Your draft is retained; retry to verify the saved version.")
      throw error
    } finally { clearTimeout(timer) }
  }

  input(event) {
    // ProseMirror transactions already report document edits, once per change.
    if (event && !["plan[title]", "plan[tag_names]"].includes(event.target.name)) return
    if (!this.editor) return
    this.setStatus("Unsaved changes", "dirty")
    this.persistDraft()
    this.scheduleSave()
  }
  scheduleSave(delay = 900) {
    clearTimeout(this.saveTimer)
    if (!this.blocked && !this.retryable) this.saveTimer = setTimeout(() => this.flush(false), delay)
  }
  submit(event) { event.preventDefault(); this.flush(true) }
  async flush(manual = false, overwriteRevision = null) {
    clearTimeout(this.saveTimer)
    if (this.editor && !this.isNew && !this.dirty() && !overwriteRevision) return true
    // A selected type may prefill a template. Choosing it or typing only a
    // title is still a local draft; the first content edit creates the plan.
    if (this.isNew && !manual && this.textareaTarget.value === this.base.content) {
      this.setStatus("Start writing to create this plan", "idle")
      return false
    }
    if (!this.editor) return this.fail("The editor is still loading. Your draft is retained.")
    if (this.composing) { this.scheduleSave(250); return }
    if (this.busy) {
      if (!manual) { this.scheduleSave(250); return false }
      await this.whenIdle()
      if (!this.active) return false
      return this.flush(manual, overwriteRevision)
    }
    if (this.blocked && !overwriteRevision) { if (manual && !this.inlineValue) this.setStatus("Resolve the conflicting edit before saving", "error"); return false }
    if (!this.snapshot().title.trim()) { this.setStatus(this.inlineValue ? "Add a document title to save" : "Add a title to save this draft", "error"); if (this.inlineValue) this.revealDetails(); return false }
    if (!manual && !this.element.checkValidity()) { this.setStatus("Correct the highlighted field to save this draft", "error"); return false }
    if (!this.element.checkValidity() && this.inlineValue) this.revealDetails()
    if (!this.element.reportValidity()) { this.setStatus("Add a document title to save", "error"); return }
    const sent = this.isNew ? (this.creationSnapshot ||= this.snapshot()) : this.snapshot(), sentBase = { ...this.base }
    this.busy = true
    this.setStatus("Saving…", "saving")
    this.persistDraft()
    try {
      const result = await this.request(this.element.action, this.isNew ? "POST" : "PATCH", {
        creation_key: this.isNew ? this.creationKey : undefined,
        plan_type_id: this.isNew ? this.element.querySelector('[name="plan_type_id"]')?.value : undefined,
        folder_id: this.isNew ? this.element.querySelector('[name="folder_id"]')?.value : undefined,
        content: sent.content, plan: { title: sent.title, tag_names: sent.tags },
        base_revision: sentBase.revision, base_metadata: { title: overwriteRevision ? this.pendingRemote.title : sentBase.title, tag_names: overwriteRevision ? this.pendingRemote.tags : sentBase.tags },
        overwrite_revision: overwriteRevision
      })
      if (this.isNew) {
        this.clearDraft()
        this.creationSnapshot = null
        if (result.inline_after_create && this.inlineValue) {
          window.history.replaceState(window.history.state, "", result.edit_url)
          const canonicalUrl = new URL(result.edit_url, window.location.href)
          canonicalUrl.searchParams.delete("edit")
          this.backTarget.href = canonicalUrl.href
        } else if (result.inline_after_create) this.pendingInlineVisitUrl = result.edit_url
        this.planIdValue = result.id
        this.element.action = result.update_url
        this.stateUrlValue = result.state_url
        this.leaseUrlValue = result.lease_url
        if (this.active) {
          if (!result.inline_after_create) window.history.replaceState(window.history.state, "", result.edit_url)
          this.subscriptionTarget.innerHTML = result.subscription_html
          this.poll = setInterval(() => { if (!document.hidden) this.refresh() }, 2500)
        }
      }
      // The server may have rebased the sent snapshot. Apply only its delta
      // to the current draft, including keystrokes that arrived during save.
      await this.whenCompositionEnds()
      this.accept(result, sent)
      if (this.inlineValue) this.element.dispatchEvent(new CustomEvent("coplan:editor-saved", { bubbles: true, detail: { revision: result.revision } }))
      const newerChanges = this.dirty()
      this.setStatus(newerChanges ? (this.inlineValue ? "Changes ready to save" : "Saved · newer changes waiting") : `All changes saved · v${result.revision}`,
        newerChanges ? "queued" : "saved")
      this.persistDraft()
      if (this.pendingInlineVisitUrl && !newerChanges && this.active) {
        const url = this.pendingInlineVisitUrl
        this.pendingInlineVisitUrl = null
        this.leaving = true
        if (window.Turbo) window.Turbo.visit(url, { action: "replace" })
        else window.location.replace(url)
      }
      return true
    } catch (error) {
      // A definite validation rejection did not create anything. A lost or
      // uncertain response keeps the original request snapshot for safe retry.
      if (this.isNew && error.status === 422) { this.creationSnapshot = null; this.persistDraft() }
      if (error.code === "overlapping_edits" || error instanceof this.merge.MergeConflict) this.showConflict(error.code === "overlapping_edits" ? error : this.pendingRemote, error.message)
      else {
        this.fail(error.message || "Offline — your draft is retained")
      }
      return false
    } finally {
      this.busy = false
      this.releaseIdle()
      if (this.active) {
        if (this.dirty() && !this.blocked && !this.retryable) this.scheduleSave()
        else if (this.refreshPending) { this.refreshPending = false; this.refresh() }
      }
    }
  }

  accept(remote, ancestor = this.base) {
    const local = this.snapshot()
    this.pendingRemote = remote
    const merged = {
      content: this.merge.mergeText(ancestor.content, local.content, remote.content),
      title: this.merge.mergeField(ancestor.title, local.title, remote.title, "title"),
      tags: this.merge.mergeField(ancestor.tags, local.tags, remote.tags, "tags")
    }
    // Update before dispatching remote steps; those transactions preserve local
    // undo history and selection and intentionally do not call input().
    if (this.active) {
      const contentChanged = this.textareaTarget.value !== merged.content
      this.updateEditors(merged.content)
      this.textareaTarget.value = merged.content
      if (contentChanged && this.inlineValue) this.element.dispatchEvent(new CustomEvent("coplan:editor-content-changed", { bubbles: true }))
      for (const [name, value] of [["plan[title]", merged.title], ["plan[tag_names]", merged.tags]]) {
        const input = this.element.querySelector(`[name="${name}"]`)
        if (input.value !== value) input.value = value
      }
      if (this.inlineValue) {
        const title = document.querySelector("#plan-header .inline-editor__title")
        if (title && title.textContent !== merged.title) title.textContent = merged.title
      }
      if (remote.url) this.backTarget.href = remote.url
    }
    this.base = { content: remote.content, title: remote.title, tags: remote.tags, revision: remote.revision }
    this.revisionValue = remote.revision
    this.retryable = false
    this.blocked = false
    this.pendingRemote = null
    if (this.active) { this.conflictTarget.hidden = true; this.draftNoticeTarget.hidden = true }
  }

  async refresh() {
    if (!this.active || this.isNew || !this.editor || this.navigating) return false
    if (this.busy || this.composing) { this.refreshPending = true; return false }
    this.busy = true
    try {
      const remote = await this.request(this.stateUrlValue)
      if (!this.active) return
      if (this.blocked) { this.pendingRemote = remote; this.latestTarget.textContent = remote.content; this.replaceTarget.hidden = false; return true }
      const wasRetryable = this.retryable
      const updated = remote.revision !== this.base.revision || remote.title !== this.base.title || remote.tags !== this.base.tags
      await this.whenCompositionEnds()
      if (!this.active) return
      this.accept(remote)
      this.persistDraft()
      if (updated) this.setStatus(this.dirty() ? `Live update merged · saving your changes` : `Updated live · v${remote.revision}`, this.dirty() ? "dirty" : "idle")
      else if (wasRetryable && !this.dirty()) this.setStatus(`All changes saved · v${remote.revision}`, "saved")
      if (this.dirty()) this.scheduleSave()
      return true
    } catch (error) {
      if (error instanceof this.merge.MergeConflict) this.showConflict(this.pendingRemote, error.message)
      else if (this.dirty()) this.fail("Offline or disconnected · draft retained. We’ll retry when connected.")
      else if (this.inlineValue && this.statusTarget.dataset.state === "saving") this.fail("Could not check the saved version")
      return false
    } finally {
      this.busy = false
      this.releaseIdle()
      if (this.refreshPending) { this.refreshPending = false; this.refresh() }
    }
  }
  stream(event) {
    const target = event.target.getAttribute?.("target")
    // Content/header streams can precede their transaction's commit. History
    // is broadcast by PlanVersion.after_create_commit, so fetch again then.
    if (!["plan-content-body", "plan-header", "plan-history-list"].includes(target)) {
      if (event.target.getAttribute?.("action") === "coplan-replace-if-clean") event.preventDefault()
      return
    }
    event.preventDefault() // Never let a reading-view stream replace the editor.
    clearTimeout(this.refreshTimer)
    this.refreshTimer = setTimeout(() => this.refresh(), 80)
  }
  async reconnect(event) {
    event?.preventDefault()
    if (!this.active || this.blocked || (this.inlineValue && !this.retryable)) return
    await this.whenIdle()
    if (!this.active) return
    this.retryable = false
    if (this.inlineValue) this.setStatus("Retrying sync…", "saving")
    if (!await this.refresh() || !this.active || this.blocked) return
    if (this.dirty()) await this.flush(true)
    else this.setStatus(`All changes saved · v${this.base.revision}`, "saved")
  }
  showConflict(remote, message) {
    this.blocked = true
    this.pendingRemote = remote
    clearTimeout(this.saveTimer)
    this.fail(this.inlineValue ? `${message}. Reload to use the saved version.` : `${message}. Your draft and the saved version are both retained. Review them before continuing.`)
    if (remote && this.active) { this.latestTarget.textContent = remote.content; this.replaceTarget.hidden = false }
    this.persistDraft()
  }
  replace(event) {
    event.preventDefault()
    if (this.pendingRemote && window.confirm(`Replace reviewed v${this.pendingRemote.revision} with this draft? The saved version remains in history.`)) this.flush(true, this.pendingRemote.revision)
  }
  async discardChanges(event) {
    event?.preventDefault()
    this.setStatus("Reverting…", "saving")
    await this.whenIdle()
    if (!this.active) return
    // A connection error has no pendingRemote; the last acknowledged
    // snapshot still gives us a useful, immediate way out.
    const latest = this.pendingRemote || this.base
    this.base = { content: latest.content, title: latest.title, tags: latest.tags, revision: latest.revision }
    this.applyBase()
    this.revisionValue = latest.revision
    if (latest.url) this.backTarget.href = latest.url
    this.blocked = false
    this.retryable = false
    this.pendingRemote = null
    this.conflictTarget.hidden = true
    this.draftNoticeTarget.hidden = true
    this.clearDraft()
    this.setStatus(`Reverted to saved version · v${latest.revision}`, "saved")
    this.refresh()
  }
  applyBase() {
    this.updateEditors(this.base.content)
    this.textareaTarget.value = this.base.content
    this.element.querySelector('[name="plan[title]"]').value = this.base.title
    this.element.querySelector('[name="plan[tag_names]"]').value = this.base.tags
    if (this.inlineValue) {
      const title = document.querySelector("#plan-header .inline-editor__title")
      if (title) title.textContent = this.base.title
      const heading = document.querySelector("#plan-header .page-header__title")
      if (heading) heading.textContent = this.base.title
    }
  }
  fail(message) {
    if (!this.active) return
    this.retryable = !this.blocked
    const status = this.inlineValue ? (this.blocked ? "Conflict — reload document to start over" : "Couldn't save · click to retry") : "Not saved"
    this.setStatus(status, this.blocked && this.inlineValue ? "conflict" : "error")
    this.errorTarget.textContent = this.blocked ? message : `Couldn't save. Your edits are still here. ${message}`
    this.conflictTarget.dataset.kind = this.blocked ? "conflict" : "save-error"
    this.retryTarget.hidden = this.blocked
    this.reviewTarget.hidden = !this.blocked
    this.replaceTarget.hidden = true
    this.conflictTarget.hidden = this.inlineValue
  }

  format(event) {
    const command = event.currentTarget.dataset.command
    if (this.editor !== this.richEditor && !["undo", "redo"].includes(command)) return
    const editor = ["undo", "redo"].includes(command) ? this.editor : this.richEditor
    editor?.command(command, event.currentTarget.value)
  }
  keepSelection(event) { if (event.target.closest("button")) event.preventDefault() }
  updateToolbar(state) {
    const rawFocused = this.editor === this.rawEditor && !!this.rawEditor
    this.toolbarTarget.querySelector('[popovertarget="coplan-insert-code"]').disabled = rawFocused
    if (rawFocused && this.codePickerTarget.matches(":popover-open")) this.codePickerTarget.hidePopover()
    this.toolbarTarget.querySelectorAll("[data-command]").forEach(button => {
      const command = button.dataset.command
      button.disabled = rawFocused
      if (button.tagName === "SELECT") { button.value = rawFocused ? "0" : state.heading || "0"; return }
      if (["undo", "redo"].includes(command)) button.disabled = !(this.editor?.historyState() || state)[command]
      else button.setAttribute("aria-pressed", String(!rawFocused && !!state[command]))
    })
  }
  style(event) { if (this.editor !== this.richEditor) return; this.richEditor?.command(event.currentTarget.value === "0" ? "paragraph" : event.currentTarget.value === "code" ? "code_block" : "heading", event.currentTarget.value) }
  updateToolOverflow() {
    if (!this.active || !this.hasMoreToolsTarget || !this.hasFormatControlsTarget) return
    const controls = this.formatControlsTarget
    const button = this.moreToolsTarget
    const overflowing = controls.scrollWidth > controls.clientWidth + 2
    button.hidden = !overflowing
    if (!overflowing) return
    const atEnd = controls.scrollLeft + controls.clientWidth >= controls.scrollWidth - 3
    button.textContent = atEnd ? "‹" : "›"
    button.setAttribute("aria-label", atEnd ? "Earlier formatting tools" : "More formatting tools")
    button.title = button.getAttribute("aria-label")
  }
  scrollTools() {
    const controls = this.formatControlsTarget
    const atEnd = controls.scrollLeft + controls.clientWidth >= controls.scrollWidth - 3
    controls.scrollBy({ left: atEnd ? -controls.scrollWidth : controls.clientWidth * 0.7, behavior: "smooth" })
  }
  keydown(event) {
    if (commandFor("editor", event) === "save") { event.preventDefault(); this.flush(true) }
  }
  beforeUnload(event) {
    if (!this.active || !this.dirty()) return
    this.persistDraft()
    event.preventDefault()
    event.returnValue = ""
  }
  back(event) {
    event.preventDefault()
    if (this.inlineValue && this.blocked) window.location.reload()
    else if (this.inlineValue && this.retryable) this.reconnect()
    else if (this.inlineValue) this.closeInline()
    else this.navigate(() => this.backTarget.href)
  }
  async closeInline() {
    if (this.navigating) return
    this.navigating = true
    try {
      await this.whenIdle()
      if (!this.active || this.blocked) return
      if (this.isNew && this.textareaTarget.value === this.base.content) {
        this.element.dispatchEvent(new CustomEvent("coplan:editor-closed", { bubbles: true,
          detail: { controller: this, snapshot: { ...this.base } } }))
        return
      }
      if (!this.snapshot().title.trim()) { this.setStatus("Add a document title to save", "error"); this.revealDetails(); return }
      if (!this.element.checkValidity()) this.revealDetails()
      if (!this.element.reportValidity()) return
      while (this.dirty()) {
        if (!await this.flush(true) || !this.active || this.blocked) return
      }
      this.element.dispatchEvent(new CustomEvent("coplan:editor-closed", { bubbles: true,
        detail: { controller: this, snapshot: { ...this.base } } }))
    } finally { this.navigating = false }
  }
  showInline(anchor, { focus = true } = {}) {
    this.inlineVisible = true
    if (focus) this.richEditor?.focusText(anchor?.text, anchor?.occurrence)
  }
  revealDetails() {
    document.querySelector("#plan-header .inline-editor__title")?.focus()
  }
  comments() {
    return Array.from(document.querySelectorAll('#plan-threads [data-anchor-text]:not([data-thread-out-of-date="true"])'), thread => ({
      id: thread.id, text: thread.dataset.anchorText,
      occurrence: Number.parseInt(thread.dataset.anchorOccurrence || "0", 10) || 0,
      status: thread.dataset.threadStatus || "open"
    }))
  }
  beforeVisit(event) {
    // A failed sync should not block unrelated navigation. disconnect()
    // retains the draft if the author chooses to return to it.
    if (this.leaving || this.retryable || this.blocked) return
    event.preventDefault()
    this.navigate(() => event.detail.url)
  }
  whenIdle() { return this.busy ? new Promise(resolve => (this.idleWaiters ||= []).push(resolve)) : Promise.resolve() }
  releaseIdle() { for (const resolve of this.idleWaiters || []) resolve(); this.idleWaiters = [] }
  async navigate(destination) {
    if (this.navigating) return
    this.navigating = true
    this.backTarget.setAttribute("aria-busy", "true")
    try {
      if (this.busy || this.dirty()) this.setStatus("Saving before going back…", "saving")
      await this.whenIdle()
      if (!this.active) return
      if (this.isNew && this.textareaTarget.value === this.base.content) {
        this.leaving = true
        window.Turbo.visit(destination())
        return
      }
      if ((!this.isNew || this.dirty()) && !this.element.reportValidity()) { this.setStatus("Correct the highlighted field before going back", "error"); return }
      if (this.blocked) { this.setStatus("Resolve the conflict before going back · draft retained", "error"); return }
      while (this.dirty()) {
        if (!await this.flush(true) || !this.active || this.blocked) return
      }
      this.leaving = true
      // Do not preview a reading-page snapshot taken before this save.
      window.Turbo.cache.clear()
      window.Turbo.visit(destination())
    } finally {
      this.navigating = false
      if (this.active) this.backTarget.removeAttribute("aria-busy")
    }
  }

  switchMode(event) { this.setMode(event.currentTarget.dataset.mode) }
  setMode(mode) {
    if (!this.richEditor || !["rich", "markdown", "dual"].includes(mode) || mode === this.mode || this.composing) return
    const sourceSelection = this.editor?.sourceSelection()
    if (mode !== "rich" && !this.rawEditor) this.rawEditor = this.richModule.createMarkdownDocument(this.rawSurfaceTarget, this.textareaTarget.value,
      content => this.editorChanged("markdown", content))
    this.mode = mode
    this.element.querySelectorAll(".document-editor__mode [data-mode]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.mode === mode)))
    try { sessionStorage.setItem(`coplan-editor-mode-${this.userIdValue}`, mode) } catch {}
    this.editor = mode === "markdown" ? this.rawEditor : this.richEditor
    this.updateEditors(this.textareaTarget.value)
    this.surfaceTarget.hidden = mode === "markdown"
    this.rawSurfaceTarget.hidden = mode === "rich"
    this.element.dataset.mode = mode
    this.surfaceTarget.querySelectorAll(".document-editor__code-language").forEach(input => { input.disabled = mode === "markdown" })
    this.element.querySelectorAll("[data-mode]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.mode === mode)))
    if (this.inlineVisible) {
      if (sourceSelection) (this.editor === this.rawEditor ? this.rawEditor.select(sourceSelection.from, sourceSelection.to) : this.richEditor.selectSource(sourceSelection.from, sourceSelection.to))
      else this.editor.view.focus()
    }
    this.updateToolbar(this.richEditor.toolbarState())
  }
  get composing() { return !!(this.richEditor?.view.composing || this.rawEditor?.view.composing) }
  focusPane(event) {
    if (this.rawSurfaceTarget.contains(event.target)) this.editor = this.rawEditor
    else if (this.surfaceTarget.contains(event.target)) this.editor = this.richEditor
    if (this.richEditor) this.updateToolbar(this.richEditor.toolbarState())
  }
  editorChanged(origin, content) {
    this.textareaTarget.value = content
    const counterpart = origin === "rich" ? this.rawEditor : this.richEditor
    // Never round-trip a composing DOM or the source of the transaction.
    if (!this.composing) counterpart?.update(content)
    this.input()
    if (this.inlineValue) this.element.dispatchEvent(new CustomEvent("coplan:editor-content-changed", { bubbles: true }))
  }
  updateEditors(content) {
    this.richEditor?.update(content)
    this.rawEditor?.update(content)
  }
  whenCompositionEnds() {
    return this.active && this.composing ? new Promise(resolve => (this.compositionWaiters ||= []).push(resolve)) : Promise.resolve()
  }
  releaseComposition() {
    for (const resolve of this.compositionWaiters || []) resolve()
    this.compositionWaiters = []
  }
  compositionEnded() {
    // ProseMirror finishes its DOM reconciliation after compositionend.
    clearTimeout(this.compositionTimer)
    const finish = () => {
      if (!this.active) return
      if (this.composing) { this.compositionTimer = setTimeout(finish, 20); return }
      this.updateEditors(this.textareaTarget.value)
      this.releaseComposition()
      if (this.dirty()) this.scheduleSave()
      if (this.refreshPending && !this.busy) { this.refreshPending = false; this.refresh() }
    }
    this.compositionTimer = setTimeout(finish, 20)
  }
  prepareCodePicker(event) {
    if (event.newState !== "open") return
    this.richEditor.captureSelection()
    this.newLanguageTarget.value = ""
    this.filterCodeLanguages()
    this.positionCodePicker(true)
  }
  codePickerToggled(event) {
    const open = event.newState === "open"
    this.newLanguageTarget.setAttribute("aria-expanded", String(open))
    if (!open) return
    this.positionCodePicker()
    this.newLanguageTarget.focus()
  }
  positionCodePicker(opening = false) {
    if (opening !== true && !this.codePickerTarget.matches(":popover-open")) return
    const trigger = this.element.querySelector('[popovertarget="coplan-insert-code"]')
    const rect = trigger.getBoundingClientRect(), picker = this.codePickerTarget
    const availableBelow = window.innerHeight - rect.bottom - 16
    const width = picker.offsetWidth || parseFloat(getComputedStyle(picker).width)
    const above = picker.offsetHeight > 0 && availableBelow < 220 && rect.top > availableBelow
    picker.style.maxHeight = `${Math.max(120, above ? rect.top - 16 : availableBelow)}px`
    picker.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - width - 8))}px`
    picker.style.top = `${above ? Math.max(8, rect.top - picker.offsetHeight - 6) : rect.bottom + 6}px`
  }
  filterCodeLanguages() {
    const query = this.newLanguageTarget.value.trim().toLowerCase()
    for (const option of this.codeOptionTargets) {
      option.hidden = !`${option.textContent} ${option.dataset.language}`.toLowerCase().includes(query)
    }
    this.highlightCodeOption(this.codeOptionTargets.find(option => !option.hidden))
    this.positionCodePicker()
  }
  highlightCodeOption(selected) {
    for (const option of this.codeOptionTargets) option.setAttribute("aria-selected", String(option === selected))
    if (selected) this.newLanguageTarget.setAttribute("aria-activedescendant", selected.id)
    else this.newLanguageTarget.removeAttribute("aria-activedescendant")
  }
  codePickerKeydown(event) {
    if (event.isComposing) return
    const options = this.codeOptionTargets.filter(option => !option.hidden)
    const selected = options.findIndex(option => option.getAttribute("aria-selected") === "true")
    if (["ArrowDown", "ArrowUp"].includes(event.key)) {
      event.preventDefault()
      const next = options[(selected + (event.key === "ArrowDown" ? 1 : -1) + options.length) % options.length]
      this.highlightCodeOption(next)
      next?.scrollIntoView({ block: "nearest" })
    } else if (event.key === "Enter") {
      event.preventDefault()
      this.insertCode()
    }
  }
  chooseCodeLanguage(event) {
    this.insertCodeLanguage(event.currentTarget.dataset.language)
  }
  insertCode() {
    const selected = this.codeOptionTargets.find(option => !option.hidden && option.getAttribute("aria-selected") === "true")
    this.insertCodeLanguage(selected?.dataset.language ?? this.newLanguageTarget.value.trim())
  }
  insertCodeLanguage(language) {
    if (this.editor !== this.richEditor) return
    if (/[\r\n`]/.test(language)) {
      this.newLanguageTarget.setCustomValidity("Use a language without backticks or line breaks.")
      this.newLanguageTarget.reportValidity()
      this.newLanguageTarget.setCustomValidity("")
      return
    }
    this.newLanguageTarget.setCustomValidity("")
    this.newLanguageTarget.closest("[popover]").hidePopover()
    this.richEditor.insertCode(language)
  }
  deleteCode(event) {
    const position = event.currentTarget.closest(".document-editor__block").coplanPosition()
    this.richEditor.deleteCode(position)
  }
  editSource(event) {
    const position = event.currentTarget.closest(".document-editor__block").coplanPosition()
    const range = this.richEditor.sourceRange(position)
    this.setMode("markdown")
    if (range) this.rawEditor.select(range.from, range.to)
  }
  async copyBlock(event) {
    const position = event.currentTarget.closest(".document-editor__block").coplanPosition()
    const range = this.richEditor.sourceRange(position)
    if (!range) return
    try {
      await navigator.clipboard.writeText(this.richEditor.content().slice(range.from, range.to))
      const button = event.currentTarget
      button.textContent = "Copied"
      setTimeout(() => { if (button.isConnected) button.textContent = "Copy" }, 1400)
    } catch { this.setStatus("Could not copy this block", "error") }
  }
  // A language edit is separate from typing code, even within history's
  // grouping delay. Undoing code must retain the chosen grammar.
  languageEditingBoundary() { this.richEditor?.closeHistory() }
  languageInput(event) { this.languageChanged(event) }
  languageChanged(event) {
    event.stopPropagation()
    const position = event.currentTarget.closest(".document-editor__block").coplanPosition()
    if (!this.richEditor.setLanguage(position, event.currentTarget.value)) {
      event.currentTarget.setCustomValidity("Use a language or fence info string without backticks or line breaks.")
      event.currentTarget.reportValidity()
    } else event.currentTarget.setCustomValidity("")
  }
  async preview(content) {
    this.previews ||= new Map()
    if (this.previews.has(content)) return this.previews.get(content)
    const response = await fetch(this.previewUrlValue, { method: "POST", signal: AbortSignal.timeout(15000),
      headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content }, body: JSON.stringify({ content }) })
    if (!response.ok || response.redirected) throw new Error("Preview unavailable")
    const html = await response.text()
    if (this.previews.size > 40) this.previews.clear()
    this.previews.set(content, html)
    return html
  }

  draftPrefix() { return `coplan-rich-draft-${this.userIdValue}-${this.isNew ? `new-${this.draftScopeValue}` : this.planIdValue}-` }
  draftKey() { return this.draftPrefix() + this.token }
  tabDraftKey() { return `coplan-editor-tab-draft-${this.userIdValue}-${this.planIdValue}` }
  tabDraftKeys() {
    try { return JSON.parse(sessionStorage.getItem(this.tabDraftKey()) || "[]").filter(key => typeof key === "string" && key.startsWith(this.draftPrefix())) }
    catch { return [] }
  }
  discardDraftOnReload() {
    if (this.isNew) return false
    if (window.__coplanEditorReloadHandled === this.draftPrefix()) return false
    const navigation = performance.getEntriesByType("navigation")[0]
    if (navigation?.type !== "reload" || navigation.name.split("#")[0] !== location.href.split("#")[0]) return false
    window.__coplanEditorReloadHandled = this.draftPrefix()
    try {
      for (const key of this.tabDraftKeys()) localStorage.removeItem(key)
      sessionStorage.removeItem(this.tabDraftKey())
    } catch {}
    return true
  }
  persistDraft() {
    if (!this.base) return
    try {
      if (this.dirty() || this.blocked) {
        localStorage.setItem(this.draftKey(), JSON.stringify({ ...this.snapshot(), revision: this.base.revision, base: this.base, creationKey: this.creationKey, creationSnapshot: this.creationSnapshot, reviewRequired: !!this.blocked, legacySource: this.legacySource, savedAt: Date.now() }))
        sessionStorage.setItem(this.tabDraftKey(), JSON.stringify([...new Set([...this.tabDraftKeys(), this.draftKey()])]))
      }
      else this.clearDraft()
    } catch { this.setStatus("Browser storage unavailable · keep this page open until saved", "error") }
  }
  restoreDraft(skipScopedDrafts = false) {
    try {
      if (!this.isNew) {
        const key = `coplan-editor-draft-${this.planIdValue}`, raw = localStorage.getItem(key)
        let data
        try { data = JSON.parse(raw) } catch {}
        if (typeof data?.content === "string" && Number.isInteger(data.revision)) {
          this.legacyDraft = { key, raw, data }
          this.legacyDraftNoticeTarget.hidden = false
        }
      }
      if (skipScopedDrafts) return
      const candidates = Object.keys(localStorage).filter(key => key.startsWith(this.draftPrefix())).map(key => ({ key, raw: localStorage.getItem(key) }))
        .map(item => { try { return { ...item, data: JSON.parse(item.raw) } } catch { return null } }).filter(item => item?.data)
        .sort((a, b) => (b.data.savedAt || 0) - (a.data.savedAt || 0))
      const saved = candidates.find(item => item.key === this.draftKey()) || candidates.find(({ data }) => data.reviewRequired || data.content !== this.base.content || data.title !== this.base.title || data.tags !== this.base.tags)
      if (!saved) return
      this.recoveredDraft = saved
      const draft = saved.data
      this.creationKey = draft.creationKey ?? this.creationKey
      this.creationSnapshot = draft.creationSnapshot
      if (draft.base) this.base = draft.base
      else if (draft.revision !== this.base.revision) { this.blocked = true; this.fail("An older draft needs review before syncing.") }
      this.textareaTarget.value = draft.content
      this.element.querySelector('[name="plan[title]"]').value = draft.title ?? this.base.title
      this.element.querySelector('[name="plan[tag_names]"]').value = draft.tags ?? this.base.tags
      this.draftNoticeTarget.hidden = false
      if (draft.legacySource?.key === `coplan-editor-draft-${this.planIdValue}`) {
        this.legacySource = draft.legacySource
        this.legacyDraftNoticeTarget.hidden = true
      }
      if (draft.reviewRequired) { this.blocked = true; this.fail("Recovered draft needs review before syncing.") }
    } catch {}
  }
  async reviewLegacyDraft(event) {
    if (!this.legacyDraft || !this.richEditor) return
    const button = event.currentTarget
    button.disabled = true
    button.setAttribute("aria-busy", "true")
    try {
      // A response already in flight must finish before installing a draft
      // that requires consent; accept() clears the previous conflict state.
      while (this.busy || this.composing) { await this.whenIdle(); await this.whenCompositionEnds(); if (!this.active) return }
      // Keep any newer draft in its own slot before opening this unowned copy.
      this.persistDraft()
      this.token = crypto.randomUUID()
      const latest = this.pendingRemote || this.base
      this.base = { ...latest }
      this.applyBase()
      this.legacySource = { key: this.legacyDraft.key, raw: this.legacyDraft.raw }
      this.recoveredDraft = null
      this.updateEditors(this.legacyDraft.data.content)
      this.textareaTarget.value = this.legacyDraft.data.content
      this.legacyDraftNoticeTarget.hidden = true
      this.showConflict(latest, "Review this older draft before replacing the saved version")
      this.editor.view.focus()
    } finally {
      button.disabled = false
      button.removeAttribute("aria-busy")
    }
  }
  clearDraft() {
    try {
      const ownedDrafts = this.tabDraftKeys().filter(key => key !== this.draftKey() && key !== this.recoveredDraft?.key)
      if (ownedDrafts.length) sessionStorage.setItem(this.tabDraftKey(), JSON.stringify(ownedDrafts))
      else sessionStorage.removeItem(this.tabDraftKey())
      localStorage.removeItem(this.draftKey())
      if (this.recoveredDraft && localStorage.getItem(this.recoveredDraft.key) === this.recoveredDraft.raw) localStorage.removeItem(this.recoveredDraft.key)
      if (this.legacySource && localStorage.getItem(this.legacySource.key) === this.legacySource.raw) localStorage.removeItem(this.legacySource.key)
      this.legacySource = null
      this.recoveredDraft = null
    } catch {}
  }
  discardDraft() { this.clearDraft(); this.applyBase(); this.blocked = false; this.draftNoticeTarget.hidden = true; this.refresh() }
}
