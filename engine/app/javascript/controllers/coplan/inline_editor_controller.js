import { Controller } from "@hotwired/stimulus"
import { captureViewport, restoreViewport } from "coplan/viewport_anchor"

// Keeps the reading page in place while the existing editor mounts on demand.
// The server-rendered body stays available behind the editor and is refreshed
// before returning to read mode, so closing never navigates or shows old text.
export default class extends Controller {
  static targets = ["reader", "editor", "template", "trigger", "error"]
  static values = { contentUrl: String, commentsUrl: String }

  open(event) {
    if (!this.hasReaderTarget || !this.hasEditorTarget || !this.hasTemplateTarget) {
      if (event?.type === "coplan:edit-request") window.Turbo?.visit(document.querySelector(".site-nav__edit")?.href)
      return // Keep the link's ordinary editor-page fallback.
    }
    event?.preventDefault()
    if (this.editing) { this.controller?.closeInline(); return }
    if (this.loading) return

    this.loading = true
    if (this.hasErrorTarget) this.errorTarget.hidden = true
    this.headerVisible = this.element.querySelector("#plan-header")?.getBoundingClientRect().bottom > 0
    this.openScrollY = window.scrollY
    this.anchor = captureViewport(this.readerTarget)
    this.setTriggers(true)
    const fragment = this.templateTarget.content.cloneNode(true)
    const form = fragment.querySelector("form.document-editor")
    if (this.latestSnapshot) {
      form.setAttribute("data-coplan--editor-revision-value", this.latestSnapshot.revision)
      form.querySelector("textarea[name=content]").value = this.latestSnapshot.content
      form.querySelector('[name="plan[title]"]').value = this.latestSnapshot.title
      form.querySelector('[name="plan[tag_names]"]').value = this.latestSnapshot.tags
    }
    this.editorTarget.hidden = false
    this.editorTarget.classList.add("inline-editor--preparing")
    this.editorTarget.append(fragment)
  }

  ready(event) {
    if (!this.loading || !this.editorTarget.contains(event.target)) return
    this.controller = event.detail.controller
    this.editorTarget.classList.remove("inline-editor--preparing")
    this.readerTarget.hidden = true
    this.editing = true
    this.loading = false
    this.setTriggers(false)
    if (!this.headerVisible) restoreViewport(this.editorTarget, this.anchor)
    this.controller.showInline(this.anchor, { focus: !this.headerVisible })
    this.element.dataset.editing = "true"
    this.mountTitle()
    if (this.headerVisible) window.scrollTo({ top: this.openScrollY, behavior: "instant" })
    this.headerObserver = new MutationObserver(() => this.mountTitle())
    const masthead = this.element.querySelector(".plan-masthead")
    if (masthead) this.headerObserver.observe(masthead, { childList: true })
    this.updateOutline()
    const sticky = document.querySelector(".site-nav__edit")
    if (sticky) sticky.dataset.editing = "true"
  }

  async closed(event) {
    if (!this.editing || this.closing || event.detail.controller !== this.controller) return
    this.closing = true
    this.setTriggers(true)
    this.editorTarget.inert = true
    const abort = new AbortController()
    const timeout = setTimeout(() => abort.abort(), 15000)
    try {
      const response = await fetch(this.contentUrlValue, { cache: "no-store", signal: abort.signal, headers: { Accept: "text/html" } })
      const revision = response.headers.get("X-CoPlan-Revision")
      if (!response.ok || !revision) throw new Error("Could not refresh the reading view. Check your connection or sign in again")
      const html = await response.text()
      if (!await this.refreshThreads()) throw new Error("Could not refresh comments. Try Done again")
      const body = this.readerTarget.querySelector("#plan-content-body")
      body.innerHTML = html
      body.setAttribute("data-coplan--live-update-revision-value", revision)
      this.latestSnapshot = event.detail.snapshot
      this.headerObserver?.disconnect()
      this.headerObserver = null
      const anchor = captureViewport(this.editorTarget)
      const headerVisible = this.element.querySelector("#plan-header")?.getBoundingClientRect().bottom > 0
      const scrollY = window.scrollY
      this.unmountTitle(event.detail.snapshot.title)
      this.readerTarget.hidden = false
      this.editorTarget.hidden = true
      if (headerVisible) window.scrollTo({ top: scrollY, behavior: "instant" })
      else restoreViewport(this.readerTarget, anchor)
      const canonicalUrl = new URL(this.controller.backTarget.href)
      if (canonicalUrl.pathname !== window.location.pathname) {
        canonicalUrl.search = window.location.search
        canonicalUrl.hash = window.location.hash
        window.history.replaceState(window.history.state, "", canonicalUrl.href)
      }
      this.editorTarget.querySelector("form.document-editor")?.remove()
      this.controller = null
      this.editing = false
      delete this.element.dataset.editing
      const sticky = document.querySelector(".site-nav__edit")
      if (sticky) delete sticky.dataset.editing
      const layout = this.readerTarget.closest(".plan-layout")
      body.dispatchEvent(new CustomEvent("coplan:content-updated", { bubbles: true }))
      this.updateOutline()
      window.Stimulus?.getControllerForElementAndIdentifier(layout, "coplan--text-selection")?.highlightAnchors()
    } catch (error) {
      this.controller?.fail(`${error.name === "AbortError" ? "The reading view timed out" : error.message}. The editor remains open with your saved draft.`)
    } finally { clearTimeout(timeout); this.editorTarget.inert = false; this.closing = false; this.setTriggers(false) }
  }

  async refreshThreads() {
    const existing = this.element.querySelector("#plan-threads")
    if (!existing || !this.hasCommentsUrlValue) return true
    const sequence = this.commentsRequest = (this.commentsRequest || 0) + 1
    try {
      const response = await fetch(this.commentsUrlValue, { cache: "no-store", headers: { Accept: "text/html" } })
      if (!response.ok) return false
      const document = new DOMParser().parseFromString(await response.text(), "text/html")
      if (sequence !== this.commentsRequest) return true
      const nextThreads = document.querySelector("#plan-threads")
      const nextDetached = document.querySelector("#plan-detached-comments")
      const nextGeneral = document.querySelector("#plan-general-comments")
      if (!nextThreads || !nextDetached || !nextGeneral) return false
      const oldThreads = new Map(Array.from(existing.children, node => [node.id, node]))
      for (const next of Array.from(nextThreads.children)) {
        const current = oldThreads.get(next.id)
        if (!current) { existing.append(next); continue }
        oldThreads.delete(next.id)
        if (current.querySelector(".thread-popover:popover-open")) {
          // Preserve the open reply form and its cursor while updating the
          // anchor data that drives both reading and editing highlights.
          for (const attribute of Array.from(next.attributes)) current.setAttribute(attribute.name, attribute.value)
        } else current.replaceWith(next)
      }
      for (const old of oldThreads.values()) old.remove()
      const detached = this.element.querySelector("#plan-detached-comments")
      if (detached) { detached.innerHTML = nextDetached.innerHTML; detached.hidden = nextDetached.hidden }
      const general = this.element.querySelector("#plan-general-comments")
      if (general) { general.innerHTML = nextGeneral.innerHTML; general.hidden = nextGeneral.hidden }
      this.controller?.richEditor?.updateComments(this.controller.comments())
      if (!this.editing) {
        const layout = this.readerTarget.closest(".plan-layout")
        window.Stimulus?.getControllerForElementAndIdentifier(layout, "coplan--text-selection")?.highlightAnchors()
      }
      return true
    } catch { return false }
  }

  error(event) {
    if (!this.editorTarget.contains(event.target)) return
    this.editorTarget.querySelector("form.document-editor")?.remove()
    this.editorTarget.hidden = true
    this.editorTarget.classList.remove("inline-editor--preparing")
    this.loading = false
    this.setTriggers(false)
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = `Could not open the editor: ${event.detail.error?.message || "please try again"}`
      this.errorTarget.hidden = false
    }
  }

  mountTitle() {
    if (!this.editing) return
    const heading = this.element.querySelector("#plan-header .page-header__title")
    if (!heading || heading.parentElement.querySelector(".inline-editor__title")) return
    const input = document.createElement("h1")
    input.className = "inline-editor__title"
    input.contentEditable = "plaintext-only"
    input.setAttribute("role", "textbox")
    input.setAttribute("aria-label", "Document title")
    input.setAttribute("aria-multiline", "false")
    input.dataset.action = "input->coplan--inline-editor#titleChanged paste->coplan--inline-editor#titlePaste keydown->coplan--inline-editor#titleKeydown"
    input.textContent = this.controller?.element.querySelector('[name="plan[title]"]')?.value || heading.textContent.trim()
    heading.hidden = true
    heading.after(input)
  }

  titleChanged(event) {
    const field = this.controller?.element.querySelector('[name="plan[title]"]')
    if (!field) return
    field.value = event.target.textContent.replace(/\s+/g, " ").slice(0, 255)
    if (event.target.textContent.length > 255) {
      event.target.textContent = field.value
      const selection = window.getSelection()
      const range = document.createRange()
      range.selectNodeContents(event.target)
      range.collapse(false)
      selection.removeAllRanges()
      selection.addRange(range)
    }
    field.dispatchEvent(new Event("input", { bubbles: true }))
    const heading = this.element.querySelector("#plan-header .page-header__title")
    if (heading) heading.textContent = field.value
  }

  titleKeydown(event) {
    if (event.key === "Enter") event.preventDefault()
  }

  titlePaste(event) {
    event.preventDefault()
    const text = event.clipboardData?.getData("text/plain")?.replace(/\s+/g, " ").slice(0, 255) || ""
    const selection = window.getSelection()
    if (!selection?.rangeCount) return
    const range = selection.getRangeAt(0)
    range.deleteContents()
    const node = document.createTextNode(text)
    range.insertNode(node)
    range.setStartAfter(node)
    range.collapse(true)
    selection.removeAllRanges()
    selection.addRange(range)
    event.currentTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  unmountTitle(title) {
    this.element.querySelector("#plan-header .inline-editor__title")?.remove()
    const heading = this.element.querySelector("#plan-header .page-header__title")
    if (heading) { heading.textContent = title; heading.hidden = false }
  }

  setTriggers(busy) {
    for (const trigger of this.triggerTargets) {
      if (busy) trigger.setAttribute("aria-busy", "true")
      else trigger.removeAttribute("aria-busy")
    }
    const sticky = document.querySelector(".site-nav__edit")
    if (busy) sticky?.setAttribute("aria-busy", "true")
    else sticky?.removeAttribute("aria-busy")
  }

  updateOutline() {
    const layout = this.readerTarget.closest(".plan-layout")
    window.Stimulus?.getControllerForElementAndIdentifier(layout, "coplan--content-nav")?.editorModeChanged()
  }

}
