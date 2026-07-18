import { Controller } from "@hotwired/stimulus"

// Markdown editor for human plan edits. Responsibilities:
// - Draft safety: persists the textarea to localStorage (per plan+revision)
//   so an accidental navigation or crash never loses typed content; restores
//   the draft on return and clears it after a successful submit.
// - Preview: posts the current markdown to the server-side preview endpoint
//   and swaps the rendered HTML into the preview pane, so the preview uses
//   the exact production rendering pipeline.
// - Ergonomics: Cmd/Ctrl+Enter submits; a beforeunload warning guards
//   unsaved changes.
export default class extends Controller {
  static targets = ["textarea", "previewPane", "writeTab", "previewTab", "draftNotice"]
  static values = { planId: String, revision: Number, previewUrl: String }

  connect() {
    this.submitting = false
    this.original = this.textareaTarget.value
    this.restoreDraft()
    this.persistDraft = this.debounce(this.persistDraft.bind(this), 500)
    this._beforeUnload = (event) => {
      if (this.dirty() && !this.submitting) {
        event.preventDefault()
        event.returnValue = ""
      }
    }
    window.addEventListener("beforeunload", this._beforeUnload)
  }

  disconnect() {
    window.removeEventListener("beforeunload", this._beforeUnload)
  }

  input() {
    this.persistDraft()
  }

  keydown(event) {
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault()
      this.element.requestSubmit ? this.element.requestSubmit() : this.element.submit()
    }
  }

  submit() {
    this.submitting = true
    this.clearDraft()
  }

  showPreview(event) {
    event.preventDefault()
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.previewUrlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token },
      body: JSON.stringify({ content: this.textareaTarget.value })
    })
      .then(response => response.ok ? response.text() : Promise.reject())
      .then(html => {
        this.previewPaneTarget.innerHTML = html
        this.previewPaneTarget.hidden = false
        this.textareaTarget.hidden = true
        this.previewTabTarget.classList.add("editor__tab--active")
        this.writeTabTarget.classList.remove("editor__tab--active")
      })
      .catch(() => {
        this.previewPaneTarget.innerHTML = '<p class="text-muted">Preview failed — check your connection and try again.</p>'
        this.previewPaneTarget.hidden = false
        this.textareaTarget.hidden = true
      })
  }

  showWrite(event) {
    event.preventDefault()
    this.previewPaneTarget.hidden = true
    this.textareaTarget.hidden = false
    this.writeTabTarget.classList.add("editor__tab--active")
    this.previewTabTarget.classList.remove("editor__tab--active")
    this.textareaTarget.focus()
  }

  discardDraft(event) {
    event.preventDefault()
    this.clearDraft()
    this.textareaTarget.value = this.original
    if (this.hasDraftNoticeTarget) this.draftNoticeTarget.hidden = true
  }

  dismissDraftNotice(event) {
    event.preventDefault()
    if (this.hasDraftNoticeTarget) this.draftNoticeTarget.hidden = true
  }

  // --- draft persistence ---

  draftKey() {
    return `coplan-editor-draft-${this.planIdValue}`
  }

  persistDraft() {
    if (!this.dirty()) {
      this.clearDraft()
      return
    }
    try {
      localStorage.setItem(this.draftKey(), JSON.stringify({
        revision: this.revisionValue,
        content: this.textareaTarget.value
      }))
    } catch { /* storage full/unavailable — draft safety is best-effort */ }
  }

  restoreDraft() {
    let draft
    try {
      draft = JSON.parse(localStorage.getItem(this.draftKey()))
    } catch { return }
    if (!draft || draft.revision !== this.revisionValue) return
    if (draft.content === this.textareaTarget.value) return
    // Only auto-restore over pristine server content — never over a
    // conflict re-render, which already carries the user's latest draft.
    if (this.textareaTarget.value !== this.original) return

    this.textareaTarget.value = draft.content
    if (this.hasDraftNoticeTarget) this.draftNoticeTarget.hidden = false
  }

  clearDraft() {
    try { localStorage.removeItem(this.draftKey()) } catch { /* noop */ }
  }

  dirty() {
    return this.textareaTarget.value !== this.original
  }

  debounce(fn, wait) {
    let timer
    return (...args) => {
      clearTimeout(timer)
      timer = setTimeout(() => fn(...args), wait)
    }
  }
}
