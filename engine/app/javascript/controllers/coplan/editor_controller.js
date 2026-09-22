import { Controller } from "@hotwired/stimulus"

// One network operation at a time. Every response is reconciled with both the
// sent snapshot and edits typed while it was in flight. Nothing clears a draft
// until the server has acknowledged that exact content.
export default class extends Controller {
  static targets = ["textarea", "surface", "status", "back", "rawSurface", "toolbar", "newLanguage", "codePicker", "codeOption", "draftNotice", "conflict", "error", "replace", "latest", "style", "subscription"]
  static values = { planId: String, userId: String, revision: Number, stateUrl: String, previewUrl: String, leaseUrl: String }

  async connect() {
    this.active = true
    this.base = { ...this.snapshot(), revision: this.revisionValue }
    this.token = crypto.randomUUID()
    this.restoreDraft()
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
        content => this.editorChanged("rich", content), state => this.updateToolbar(state), source => this.preview(source))
      this.editor = this.richEditor
      this.updateToolbar(this.editor.toolbarState())
      try { this.setMode(sessionStorage.getItem(`coplan-editor-mode-${this.userIdValue}`) || "rich") } catch {}
      this.setStatus(this.dirty() ? "Recovered draft · waiting to sync" : this.isNew ? "Private draft" : `All changes saved · v${this.base.revision}`)
      // Retire leases from the previous prototype, without acquiring one.
      if (this.leaseUrlValue) await this.request(this.leaseUrlValue, "DELETE", {}).catch(() => {})
      if (!this.active) return
      if (!this.isNew) {
        await this.refresh()
        if (!this.active) return
        this.poll = setInterval(() => { if (!document.hidden) this.refresh() }, 2500)
        if (this.dirty()) this.scheduleSave()
      }
    } catch (error) { this.fail(error.message || "The editor could not load. Reload to retry.") }
  }

  disconnect() {
    this.active = false
    this.subscriptionObserver?.disconnect()
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
  setStatus(message, state = "saved") { if (!this.active) return; this.statusTarget.textContent = message; this.statusTarget.dataset.state = state }

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
    if (!this.blocked) this.saveTimer = setTimeout(() => this.flush(false), delay)
  }
  submit(event) { event.preventDefault(); this.flush(true) }
  async flush(manual = false, overwriteRevision = null) {
    clearTimeout(this.saveTimer)
    if (this.editor && !this.isNew && !this.dirty() && !overwriteRevision) return true
    if (this.isNew && !manual && !this.textareaTarget.value.trim()) { this.setStatus("Add document content to save", "dirty"); return false }
    if (!this.editor) return this.fail("The editor is still loading. Your draft is retained.")
    if (this.composing) { this.scheduleSave(250); return }
    if (this.busy) {
      if (!manual) { this.scheduleSave(250); return false }
      await this.whenIdle()
      if (!this.active) return false
      return this.flush(manual, overwriteRevision)
    }
    if (this.blocked && !overwriteRevision) { if (manual) this.setStatus("Resolve the conflicting edit before saving", "error"); return }
    if (!manual && !this.element.checkValidity()) { this.setStatus("Add a title to save this draft", "dirty"); return false }
    if (!this.element.reportValidity()) { this.setStatus("Add a document title to save", "error"); return }
    const sent = this.snapshot(), sentBase = { ...this.base }
    this.busy = true
    this.setStatus("Saving…", "saving")
    this.persistDraft()
    try {
      const result = await this.request(this.element.action, this.isNew ? "POST" : "PATCH", {
        content: sent.content, plan: { title: sent.title, tag_names: sent.tags },
        base_revision: sentBase.revision, base_metadata: { title: overwriteRevision ? this.pendingRemote.title : sentBase.title, tag_names: overwriteRevision ? this.pendingRemote.tags : sentBase.tags },
        overwrite_revision: overwriteRevision, change_summary: this.element.querySelector('[name="change_summary"]').value
      })
      if (this.isNew) {
        this.clearDraft()
        this.planIdValue = result.id
        this.element.action = result.update_url
        this.stateUrlValue = result.state_url
        this.leaseUrlValue = result.lease_url
        if (this.active) {
          window.history.replaceState(window.history.state, "", result.edit_url)
          this.subscriptionTarget.innerHTML = result.subscription_html
          this.poll = setInterval(() => { if (!document.hidden) this.refresh() }, 2500)
        }
      }
      // The server may have rebased the sent snapshot. Apply only its delta
      // to the current draft, including keystrokes that arrived during save.
      await this.whenCompositionEnds()
      this.accept(result, sent)
      this.setStatus(this.dirty() ? "Saved · newer changes waiting" : `All changes saved · v${result.revision}`, this.dirty() ? "dirty" : "saved")
      this.persistDraft()
      return true
    } catch (error) {
      if (error.code === "overlapping_edits" || error instanceof this.merge.MergeConflict) this.showConflict(error.code === "overlapping_edits" ? error : this.pendingRemote, error.message)
      else {
        this.fail(error.message || "Offline — your draft is retained")
        this.retryable = true
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
      this.updateEditors(merged.content)
      this.textareaTarget.value = merged.content
      for (const [name, value] of [["plan[title]", merged.title], ["plan[tag_names]", merged.tags]]) {
        const input = this.element.querySelector(`[name="${name}"]`)
        if (input.value !== value) input.value = value
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
    if (!this.active || this.isNew || !this.editor || this.navigating) return
    if (this.busy || this.composing) { this.refreshPending = true; return }
    this.busy = true
    try {
      const remote = await this.request(this.stateUrlValue)
      if (!this.active) return
      if (this.blocked) { this.pendingRemote = remote; this.latestTarget.textContent = remote.content; this.replaceTarget.hidden = false; return }
      const updated = remote.revision !== this.base.revision || remote.title !== this.base.title || remote.tags !== this.base.tags
      await this.whenCompositionEnds()
      if (!this.active) return
      this.accept(remote)
      this.persistDraft()
      if (updated) this.setStatus(this.dirty() ? `Live update merged · saving your changes` : `Updated live · v${remote.revision}`, this.dirty() ? "dirty" : "saved")
      if (this.dirty()) this.scheduleSave()
    } catch (error) {
      if (error instanceof this.merge.MergeConflict) this.showConflict(this.pendingRemote, error.message)
      else if (this.dirty()) this.fail("Offline or disconnected · draft retained. We’ll retry when connected.")
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
  reconnect() { this.retryable = false; this.refresh().then(() => { if (!this.blocked && this.dirty()) this.flush(true) }) }
  showConflict(remote, message) {
    this.blocked = true
    this.pendingRemote = remote
    clearTimeout(this.saveTimer)
    this.fail(`${message}. Your draft and the saved version are both retained. Review them before continuing.`)
    if (remote && this.active) { this.latestTarget.textContent = remote.content; this.replaceTarget.hidden = false }
    this.persistDraft()
  }
  replace(event) {
    event.preventDefault()
    if (this.pendingRemote && window.confirm(`Replace reviewed v${this.pendingRemote.revision} with this draft? The saved version remains in history.`)) this.flush(true, this.pendingRemote.revision)
  }
  useLatest() {
    if (!this.pendingRemote || !window.confirm("Use the saved version? Download your draft first if you want to keep a separate copy.")) return
    const latest = this.pendingRemote
    this.base = { content: latest.content, title: latest.title, tags: latest.tags, revision: latest.revision }
    this.applyBase()
    this.blocked = false
    this.pendingRemote = null
    this.conflictTarget.hidden = true
    this.clearDraft()
    this.setStatus(`All changes saved · v${latest.revision}`)
  }
  applyBase() {
    this.updateEditors(this.base.content)
    this.textareaTarget.value = this.base.content
    this.element.querySelector('[name="plan[title]"]').value = this.base.title
    this.element.querySelector('[name="plan[tag_names]"]').value = this.base.tags
  }
  fail(message) { if (!this.active) return; this.setStatus("Not saved · draft retained", "error"); this.errorTarget.textContent = message; this.conflictTarget.hidden = false }

  format(event) {
    const command = event.currentTarget.dataset.command
    const editor = ["undo", "redo"].includes(command) ? this.editor : this.richEditor
    editor?.command(command, event.currentTarget.value)
  }
  keepSelection(event) { if (event.target.closest("button")) event.preventDefault() }
  updateToolbar(state) {
    this.element.querySelectorAll("[data-command]").forEach(button => {
      const command = button.dataset.command
      if (button.tagName === "SELECT") { button.value = state.heading || "0"; return }
      if (["undo", "redo"].includes(command)) button.disabled = !(this.editor?.historyState() || state)[command]
      else button.setAttribute("aria-pressed", String(!!state[command]))
    })
  }
  style(event) { this.richEditor?.command(event.currentTarget.value === "0" ? "paragraph" : event.currentTarget.value === "code" ? "code_block" : "heading", event.currentTarget.value) }
  keydown(event) {
    if (!event.defaultPrevented && (event.metaKey || event.ctrlKey) && ["s", "Enter"].includes(event.key)) { event.preventDefault(); this.flush(true) }
  }
  beforeUnload(event) { if (this.dirty()) { this.persistDraft(); event.preventDefault(); event.returnValue = "" } }
  back(event) { event.preventDefault(); this.navigate(() => this.backTarget.href) }
  beforeVisit(event) {
    if (this.leaving) return
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
    if (mode !== "rich" && !this.rawEditor) this.rawEditor = this.richModule.createMarkdownDocument(this.rawSurfaceTarget, this.textareaTarget.value,
      content => this.editorChanged("markdown", content))
    this.mode = mode
    try { sessionStorage.setItem(`coplan-editor-mode-${this.userIdValue}`, mode) } catch {}
    this.editor = mode === "markdown" ? this.rawEditor : this.richEditor
    this.updateEditors(this.textareaTarget.value)
    this.surfaceTarget.hidden = mode === "markdown"
    this.rawSurfaceTarget.hidden = mode === "rich"
    this.toolbarTarget.hidden = mode === "markdown"
    this.element.dataset.mode = mode
    this.surfaceTarget.querySelectorAll(".document-editor__code-language").forEach(input => { input.disabled = mode === "markdown" })
    this.element.querySelectorAll("[data-mode]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.mode === mode)))
    this.editor.view.focus()
    if (mode !== "markdown") this.updateToolbar(this.richEditor.toolbarState())
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

  draftPrefix() { return `coplan-rich-draft-${this.userIdValue}-${this.planIdValue}-` }
  draftKey() { return this.draftPrefix() + this.token }
  persistDraft() {
    if (!this.base) return
    try {
      if (this.dirty()) localStorage.setItem(this.draftKey(), JSON.stringify({ ...this.snapshot(), revision: this.base.revision, base: this.base, savedAt: Date.now() }))
      else this.clearDraft()
    } catch { this.setStatus("Browser storage unavailable · keep this page open until saved", "error") }
  }
  restoreDraft() {
    try {
      const candidates = Object.keys(localStorage).filter(key => key.startsWith(this.draftPrefix())).map(key => ({ key, raw: localStorage.getItem(key) }))
        .map(item => { try { return { ...item, data: JSON.parse(item.raw) } } catch { return null } }).filter(item => item?.data)
        .sort((a, b) => (b.data.savedAt || 0) - (a.data.savedAt || 0))
      const saved = candidates.find(item => item.key === this.draftKey()) || candidates.find(({ data }) => data.content !== this.base.content || data.title !== this.base.title || data.tags !== this.base.tags)
      if (!saved) return
      this.recoveredDraft = saved
      const draft = saved.data
      if (draft.base) this.base = draft.base
      else if (draft.revision !== this.base.revision) { this.blocked = true; this.fail("An older draft needs review before syncing.") }
      this.textareaTarget.value = draft.content
      this.element.querySelector('[name="plan[title]"]').value = draft.title || this.base.title
      this.element.querySelector('[name="plan[tag_names]"]').value = draft.tags || ""
      this.draftNoticeTarget.hidden = false
    } catch {}
  }
  clearDraft() {
    try {
      localStorage.removeItem(this.draftKey())
      if (this.recoveredDraft && localStorage.getItem(this.recoveredDraft.key) === this.recoveredDraft.raw) localStorage.removeItem(this.recoveredDraft.key)
      this.recoveredDraft = null
    } catch {}
  }
  discardDraft() { this.clearDraft(); this.applyBase(); this.blocked = false; this.draftNoticeTarget.hidden = true; this.refresh() }
  download() {
    const url = URL.createObjectURL(new Blob([this.textareaTarget.value], { type: "text/markdown" }))
    const link = document.createElement("a"); link.href = url; link.download = "coplan-draft.md"; link.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }
}
