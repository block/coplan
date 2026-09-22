import { Controller } from "@hotwired/stimulus"

// The panel stays inside this Stimulus scope, even in the modal expander.
// Only signed source ranges cross the wire; SVG ids are render-time lookup
// keys, and never become comment identities.
export default class extends Controller {
  static targets = ["panel", "quote", "discussions", "token", "body", "outdated", "composer", "discussionActions", "newComment"]

  connect() {
    this.drafts = new Map()
    this.replyDrafts = new Map()
    this.panelHome = document.createComment("element comment panel")
    this.panelTarget.before(this.panelHome)
    this.threads = this.element.querySelector("#plan-threads")
    this.observer = new MutationObserver(() => this.refresh())
    if (this.threads) this.observer.observe(this.threads, { childList: true, subtree: true })
    this.panelObserver = new ResizeObserver(() => this.positionPanel())
    this.panelObserver.observe(this.panelTarget)
    this.refresh()
  }

  disconnect() {
    this.observer?.disconnect()
    this.panelObserver?.disconnect()
    this.panelHome?.remove()
  }

  beforeCache() {
    this.dismiss()
    this.panelHome.after(this.panelTarget)
  }

  key(event) {
    if (event.ctrlKey || event.metaKey || event.altKey || !["Enter", " ", "c", "C"].includes(event.key) || event.target.closest("a, button, input, textarea, [contenteditable]")) return
    if (!window.getSelection().isCollapsed) return
    const element = event.target.closest("[data-source-target]")
    if (!element) return
    const diagram = element.closest(".mermaid-diagram, .expander--diagram")
    if (diagram && (event.key.toLowerCase() === "c" || !diagram.classList.contains("is-comment-mode"))) return
    event.preventDefault()
    event.stopPropagation()
    this.show(element)
  }

  focusComposer() {
    const textarea = this.composerTarget.hidden
      ? this.discussionsTarget.querySelector(".thread-popover__reply textarea")
      : this.bodyTarget
    if (textarea) textarea.focus({ preventScroll: true })
    else this.focusClose()
  }

  focusClose() {
    Array.from(this.panelTarget.querySelectorAll('[aria-label="Close element comments"]'))
      .find(button => button.getClientRects().length)?.focus({ preventScroll: true })
  }

  discussionKey(event) {
    if (event.ctrlKey || event.metaKey || event.altKey || event.target.closest("input, textarea, select, [contenteditable]")) return
    const discussion = event.target.closest(".source-comments__discussion") || this.discussionsTarget
    if (event.key === "r") {
      discussion.querySelector(".thread-popover__reply textarea")?.focus({ preventScroll: true })
    } else if (event.key === "e") {
      discussion.querySelector('form[data-action-name="resolve"]')?.requestSubmit()
    } else return
    event.preventDefault()
    event.stopPropagation()
  }

  select(event) {
    if (event.target.closest("a, input, button, mark.anchor-highlight") || !window.getSelection().isCollapsed) return
    const element = event.target.closest("[data-source-target]")
    if (!element) return
    const diagram = element.closest(".mermaid-diagram, .expander--diagram")
    if (diagram && !diagram.classList.contains("is-comment-mode") && !event.target.closest("[data-source-badge]")) return
    if (element.matches("td, th") && !event.target.closest("[data-source-badge]")) {
      this.browse(element)
      element.focus({ preventScroll: true })
      return
    }
    this.show(element)
    return true
  }

  show(element, includeResolved = false) {
    // Badges are rebuilt on broadcasts; anchor to the lasting connection.
    if (element.ownerSVGElement && JSON.parse(element.dataset.sourceTarget).kind === "mermaid_edge") {
      element = Array.from(element.ownerSVGElement.querySelectorAll("path.flowchart-link[data-source-target]:not(.source-edge-hit)"))
        .find(path => path.dataset.sourceTarget === element.dataset.sourceTarget) || element
    }
    this.includeResolved = includeResolved
    this.openThreadIds = new Set()
    this.clearBrowse()
    this.saveReplyDrafts()
    if (this.selection) this.drafts.set(this.selection.token, this.bodyTarget.value)
    const target = JSON.parse(element.dataset.sourceTarget)
    this.selection = target
    this.showingOutdated = false
    this.composing = false
    this.trigger = element
    const preview = element.cloneNode(true)
    preview.querySelectorAll("[data-source-badge], button").forEach(el => el.remove())
    this.quoteTarget.closest(".comment-form__anchor").hidden = target.kind === "table_cell"
    this.quoteTarget.textContent = target.kind === "table_cell" ? "" : target.kind === "mermaid_diagram" ? target.label :
      preview.textContent.trim() || target.label
    this.tokenTarget.value = target.token
    this.bodyTarget.value = this.drafts.get(target.token) || ""
    this.element.querySelector("#source-comment-error").textContent = ""

    const panel = this.panelTarget
    const dialog = element.closest("dialog.expander")
    try { panel.hidePopover() } catch {}
    if (dialog) dialog.append(panel)
    else this.panelHome.after(panel)
    this.renderDiscussions(true)
    this.paintSelection()
    panel.showPopover()
    this.positionPanel()
    this.focusComposer()
  }

  browse(element) {
    this.clearBrowse()
    this.browseTarget = element
    this.trigger = element
    element.classList.add("is-source-browsing")
  }

  browseFocus(event) {
    if (event.target !== this.browseTarget && event.target.matches("td[data-source-target], th[data-source-target]")) this.browse(event.target)
  }

  commentOnCell(event) {
    const dialog = event.currentTarget.closest("dialog")
    const cell = dialog?.contains(this.browseTarget) ? this.browseTarget : dialog?.querySelector(".is-cursor[data-source-target]")
    if (cell) this.show(cell)
  }

  commentOnDiagram(event) {
    this.show(event.currentTarget)
  }

  clearBrowse() {
    this.browseTarget?.classList.remove("is-source-browsing")
    this.browseTarget = null
  }

  dismissFromOutside(event) {
    if (!this.panelTarget.matches(":popover-open") || this.panelTarget.contains(event.target)) return
    // Preserve drafts without consuming the click or moving focus away from
    // whatever the reader is choosing next (including another source target).
    this.dismiss(null, false)
  }

  dismiss(event, restoreFocus = true) {
    if (event && !this.panelTarget.matches(":popover-open")) return
    event?.preventDefault()
    event?.stopPropagation()
    if (this.selection) this.drafts.set(this.selection.token, this.bodyTarget.value)
    this.saveReplyDrafts()
    this.clearBrowse()
    try { this.panelTarget.hidePopover() } catch {}
    this.selection = null
    this.openThreadIds = new Set()
    this.showingOutdated = false
    this.paintSelection()
    if (restoreFocus) this.trigger?.focus({ preventScroll: true })
  }

  // Expander sends this before removing its dialog. Preserve the one panel
  // (and any typed draft) instead of deleting it with the modal.
  expanderClosing(event) {
    if (!event.target.contains(this.panelTarget) && !event.target.contains(this.browseTarget)) return
    this.dismiss()
    this.panelHome.after(this.panelTarget)
  }

  submitted(event) {
    if (!event.detail.success) return
    if (event.target.dataset.actionName === "resolve") {
      this.dismiss()
      return
    }
    if (event.target.contains(this.bodyTarget)) {
      this.bodyTarget.value = ""
      this.drafts.delete(this.selection?.token)
      this.composing = false
    } else {
      event.target.querySelectorAll("textarea").forEach(textarea => { textarea.value = "" })
      this.replyDrafts.delete(event.target.closest("[data-thread-id]")?.dataset.threadId)
    }
    // Turbo renders the stream response before dispatching submit-end.
    this.renderDiscussions()
  }

  matchingThreads(target) {
    return Array.from(this.threads?.children || []).filter(thread =>
      thread.dataset.anchorDigest === target.digest && thread.dataset.anchorKind === target.kind && thread.dataset.outOfDate !== "true" &&
      Number(thread.dataset.anchorStart) === target.start && Number(thread.dataset.anchorEnd) === target.end &&
      thread.dataset.anchorText === target.text)
  }

  saveReplyDrafts() {
    this.discussionsTarget.querySelectorAll("[data-thread-id]").forEach(thread => {
      const textarea = thread.querySelector("textarea")
      if (textarea) this.replyDrafts.set(thread.dataset.threadId, textarea.value)
    })
  }

  showOutdated() {
    this.dismiss()
    this.showingOutdated = true
    this.composerTarget.hidden = true
    this.panelHome.after(this.panelTarget)
    this.renderDiscussions(true)
    this.panelTarget.showPopover()
    this.positionPanel()
    this.focusClose()
  }

  openThread(event) {
    const data = this.threads?.querySelector(`[data-thread-id="${CSS.escape(event.detail.threadId)}"]`)
    if (!data) return
    if (data.dataset.outOfDate === "true") this.showOutdated()
    else {
      const element = Array.from(this.element.querySelectorAll("[data-source-target]")).find(el =>
        !el.classList.contains("source-edge-hit") && this.matchingThreads(JSON.parse(el.dataset.sourceTarget)).includes(data))
      if (!element) return // Mermaid may still be rendering; the caller retries.
      element.scrollIntoView({ block: "center", behavior: "instant" })
      this.show(element, data.dataset.threadStatus === "resolved")
    }
    event.preventDefault()
    const thread = Array.from(this.discussionsTarget.children).find(el => el.dataset.threadId === event.detail.threadId)
    thread?.scrollIntoView({ block: "nearest" })
  }

  outdatedThreads() {
    return Array.from(this.threads?.children || []).filter(thread =>
      thread.dataset.anchorKind && thread.dataset.outOfDate === "true")
  }

  renderDiscussions(force = false) {
    if (!this.selection && !this.showingOutdated) return
    // Incoming broadcasts must never destroy a reply someone is writing.
    if (!force && Array.from(this.discussionsTarget.querySelectorAll("textarea")).some(el => el.value)) return
    const matches = this.showingOutdated ? this.outdatedThreads() : this.matchingThreads(this.selection)
    const openThreads = matches.filter(thread => thread.dataset.threadStatus === "open")
    if (this.openThreadIds?.size && !openThreads.length && !this.composing && !this.bodyTarget.value) {
      this.dismiss()
      return
    }
    this.openThreadIds = new Set(openThreads.map(thread => thread.dataset.threadId))
    const threads = this.showingOutdated || this.includeResolved ? matches : openThreads
    const discussions = threads.map(thread => {
      const copy = thread.cloneNode(true)
      copy.removeAttribute("id")
      copy.removeAttribute("data-anchor-text")
      copy.className = "source-comments__discussion"
      for (const name of ["viewer-is-plan-author", "viewer-is-thread-author"]) {
        copy.classList.toggle(name, thread.classList.contains(name))
      }
      copy.querySelectorAll("[id]").forEach(el => el.removeAttribute("id"))
      const popover = copy.querySelector("[popover]")
      popover.removeAttribute("popover")
      popover.className = "source-comments__thread"
      popover.removeAttribute("style")
      const quote = copy.querySelector(".thread-popover__quote")
      if (thread.dataset.anchorKind === "table_cell" && !this.showingOutdated) quote?.remove()
      else if (!this.showingOutdated && quote) quote.textContent = this.quoteTarget.textContent
      const textarea = copy.querySelector("textarea")
      if (textarea) textarea.value = this.replyDrafts.get(copy.dataset.threadId) || ""
      return copy
    })
    this.discussionsTarget.replaceChildren(...discussions)
    this.composerTarget.hidden = this.showingOutdated || (threads.length > 0 && !this.composing && !this.bodyTarget.value)
    this.discussionActionsTarget.hidden = !this.composerTarget.hidden
    this.newCommentTarget.hidden = this.showingOutdated
    this.panelTarget.classList.toggle("comment-form", !this.composerTarget.hidden)
    this.panelTarget.classList.toggle("thread-popover", this.composerTarget.hidden)
    this.positionPanel()
  }

  newComment() {
    this.composing = true
    this.saveReplyDrafts()
    this.renderDiscussions(true)
    this.bodyTarget.focus({ preventScroll: true })
  }

  positionPanel(event) {
    const panel = this.panelTarget
    if (!panel.matches(":popover-open") || (event?.type === "scroll" && panel.contains(event.target))) return
    const mobile = window.matchMedia("(max-width: 640px)").matches
    panel.classList.toggle("comment-form--sheet", mobile && !this.composerTarget.hidden)
    panel.classList.toggle("thread-popover--sheet", mobile && this.composerTarget.hidden)
    if (mobile) {
      panel.style.top = ""
      panel.style.left = ""
      return
    }
    const rect = (this.showingOutdated ? this.outdatedTarget : this.trigger)?.getBoundingClientRect()
    if (!rect) return
    let left = rect.right + 12
    if (left + panel.offsetWidth > window.innerWidth - 16) left = rect.left - panel.offsetWidth - 12
    panel.style.left = `${Math.max(16, Math.min(left, window.innerWidth - panel.offsetWidth - 16))}px`
    panel.style.top = `${Math.max(16, Math.min(rect.top, window.innerHeight - panel.offsetHeight - 16))}px`
  }

  refresh() {
    const outdatedCount = this.outdatedThreads().length
    this.outdatedTarget.hidden = outdatedCount === 0
    this.outdatedTarget.textContent = `Outdated element comments (${outdatedCount})`
    // Badges are derived from the shared thread data on each broadcast;
    // expanded clones and document elements consequently share identity.
    this.element.querySelectorAll("[data-source-badge], .source-edge-badges").forEach(el => el.remove())
    this.element.querySelectorAll("[data-source-target]").forEach(element => {
      if (element.classList.contains("source-edge-hit")) return
      const target = JSON.parse(element.dataset.sourceTarget)
      const threads = this.matchingThreads(target)
      element.classList.toggle("has-source-comments", threads.some(t => t.dataset.threadStatus === "open"))
      if (target.kind === "mermaid_diagram") {
        element.hidden = !element.classList.contains("has-source-comments") &&
          !element.closest(".is-comment-mode")
      }
      element.setAttribute("aria-label", `${target.label}. ${threads.length} discussions. Press C or Enter to comment.`)
      // Measure before inserting badges so subsequent markers don't shift
      // with the growing SVG group's bounding box.
      if (element.classList.contains("source-edge-label")) return
      const bounds = threads.length && element.ownerSVGElement ? element.getBBox() : null
      threads.forEach((thread, index) => this.addBadge(element, thread, index, bounds))
    })
    this.paintSelection()
    this.renderDiscussions()
    this.element.dispatchEvent(new CustomEvent("coplan:anchors-updated", { bubbles: true }))
  }

  paintSelection() {
    this.element.querySelectorAll("[data-source-target]").forEach(element => {
      const target = JSON.parse(element.dataset.sourceTarget)
      element.classList.toggle("is-source-selected", this.selection?.token === target.token)
    })
  }

  addBadge(element, thread, index, bounds) {
    const svg = element.ownerSVGElement
    const badge = svg ? document.createElementNS("http://www.w3.org/2000/svg", "g") : document.createElement("span")
    badge.dataset.sourceBadge = ""
    badge.dataset.threadId = thread.id
    badge.classList.add("source-thread-badge", "anchor-highlight", `anchor-highlight--${thread.dataset.threadStatus}`)
    badge.setAttribute("aria-label", `Open discussion ${index + 1}`)
    if (svg) {
      const path = element.matches("path") ? element : null
      let point = { x: bounds.x + bounds.width + index * 18, y: bounds.y }
      let layer
      if (path) {
        const root = path.parentElement.parentElement
        layer = root.querySelector(":scope > .source-edge-badges")
        if (!layer) {
          layer = document.createElementNS(svg.namespaceURI, "g")
          layer.classList.add("source-edge-badges")
          root.append(layer)
        }
        const label = Array.from(svg.querySelectorAll(".source-edge-label"))
          .find(label => label.dataset.sourceTarget === path.dataset.sourceTarget)
        const anchor = label || path
        const box = label?.getBBox()
        const midpoint = path.getPointAtLength(path.getTotalLength() / 2)
        point = label ? { x: box.x + box.width + 8 + index * 18, y: box.y - 4 } :
          { x: midpoint.x + index * 18, y: midpoint.y - 10 }
        point = new DOMPoint(point.x, point.y).matrixTransform(anchor.getCTM()).matrixTransform(layer.getCTM().inverse())
      }
      badge.setAttribute("transform", `translate(${point.x}, ${point.y})`)
      const circle = document.createElementNS(svg.namespaceURI, "circle")
      circle.setAttribute("r", "7")
      const text = document.createElementNS(svg.namespaceURI, "text")
      text.setAttribute("dy", ".35em")
      text.textContent = String(index + 1)
      badge.append(circle, text)
      if (path) {
        badge.dataset.sourceTarget = element.dataset.sourceTarget
        badge.dataset.action = "click->coplan--source-comments#select keydown->coplan--source-comments#key"
        layer.append(badge)
      } else element.append(badge)
    } else {
      badge.textContent = String(index + 1)
      badge.style.right = `${6 + index * 24}px`
      element.append(badge)
    }
  }
}
