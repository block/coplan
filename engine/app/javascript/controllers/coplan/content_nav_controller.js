import { Controller } from "@hotwired/stimulus"
import { registerShortcuts, commandFor } from "coplan/shortcuts"

const STORAGE_KEY = "coplan:content-nav-visible"
const OUTLINE_STATE_PREFIX = "coplan:outline-expanded:"
// Outlines with more entries than this open with their subtrees folded.
// Shorter ones render flat, exactly as before collapsing existed.
const COLLAPSE_THRESHOLD = 12
const CHEVRON = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>'

export default class extends Controller {
  static targets = ["sidebar", "list", "content", "toggleBtn", "showBtn", "editorToggleBtn", "commentsCount", "treeControls"]
  static values = { visible: { type: Boolean, default: true }, planId: String }

  connect() {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (stored !== null) {
      this.visibleValue = stored === "true"
    }

    this.buildToc()
    this.revealHashTarget()
    this.setupScrollTracking()

    this.releaseShortcuts = registerShortcuts(this, "outline", event => this.handleKeydown(event))

    this._handleAnchorsUpdated = () => this.updateCommentBadges()
    this.element.addEventListener("coplan:anchors-updated", this._handleAnchorsUpdated)
  }

  disconnect() {
    if (this._scrollHandler) {
      window.removeEventListener("scroll", this._scrollHandler)
    }
    this.releaseShortcuts()
    if (this._handleAnchorsUpdated) {
      this.element.removeEventListener("coplan:anchors-updated", this._handleAnchorsUpdated)
    }
    clearTimeout(this._editorTocTimer)
  }

  documentCommentCountChanged(event) {
    if (this.hasCommentsCountTarget) this.commentsCountTarget.textContent = event.detail.count || ""
  }

  buildToc() {
    const editing = this.element.closest("[data-editing='true']")
    const editorRoot = editing?.querySelector(".inline-editor .ProseMirror")
    if (editorRoot) { this.buildEditorToc(editorRoot); return }
    this._editorRoot = null
    const documentRoot = this.contentTarget
    if (!documentRoot.querySelector(".markdown-rendered") && !documentRoot.classList.contains("markdown-rendered")) return

    this._itemsById = new Map()
    // A document renders one .markdown-rendered; a deck renders one per
    // slide. Scan the whole content column either way — scanning the first
    // rendered block gave a deck an outline of slide 1 and nothing else.
    const headings = Array.from(documentRoot.querySelectorAll(".markdown-rendered h1, .markdown-rendered h2, .markdown-rendered h3"))
    // The title is part of the document and is a navigable heading too.
    this._headings = headings

    if (headings.length === 0) {
      this.assembleOutline([])
      this.sidebarTarget.style.display = "none"
      if (this.hasShowBtnTarget) this.showBtnTarget.style.display = "none"
      return
    }
    this.sidebarTarget.style.display = ""
    if (this.hasShowBtnTarget) Object.assign(this.showBtnTarget.style, { display: "", visibility: "" })

    // Commonmarker supplies an empty self-link inside each heading. Promote
    // its generated fragment to the heading itself when that heading does
    // not already own a different server-assigned id. Visible or non-self
    // links are authored content and stay untouched.
    const promotedAnchors = new Map()
    this._headings.forEach(heading => {
      const anchor = Array.from(heading.querySelectorAll("a.anchor[id]"))
        .find(candidate => candidate.textContent.trim() === "" &&
          candidate.getAttribute("href") === `#${candidate.id}` &&
          (!heading.id || heading.id === candidate.id))
      if (anchor) promotedAnchors.set(heading, anchor)
    })

    const headingSet = new Set(this._headings)
    const promotedAnchorSet = new Set(promotedAnchors.values())
    const usedIds = new Set(
      Array.from(document.querySelectorAll("[id]"))
        .filter(element => !headingSet.has(element) && !promotedAnchorSet.has(element))
        .map(element => element.id)
    )
    const pageUrl = new URL(window.location.href)
    pageUrl.search = ""
    const entries = []

    this._headings.forEach((heading, index) => {
      heading.querySelector(":scope > .section-permalink")?.remove()
      const promotedAnchor = promotedAnchors.get(heading)
      const headingText = heading.textContent.trim().replace(/\s+/g, " ")
      let baseId = heading.id || promotedAnchor?.id || this.slugify(headingText) || `section-${index + 1}`
      let id = baseId
      let suffix = 2
      while (usedIds.has(id)) {
        id = `${baseId}-${suffix++}`
      }
      heading.id = id
      promotedAnchor?.remove()
      heading.classList.add("section-heading")
      usedIds.add(id)

      let title = heading.querySelector(":scope > .section-heading__title")
      if (!title) {
        title = document.createElement("span")
        title.className = "section-heading__title"
        while (heading.firstChild) title.appendChild(heading.firstChild)
        heading.appendChild(title)
      }

      const permalink = document.createElement("a")
      const sectionUrl = new URL(pageUrl)
      sectionUrl.hash = id
      permalink.className = "section-permalink"
      permalink.href = sectionUrl.href
      permalink.dataset.action = "click->coplan--content-nav#copySectionLink"
      permalink.dataset.sectionTitle = headingText
      permalink.setAttribute("aria-label", `Copy link to ${headingText}`)
      permalink.title = "Copy link to this section"
      permalink.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>'
      heading.appendChild(permalink)

      entries.push(this.outlineEntry(id, heading.tagName, headingText, event => this.handleLinkClick(event, heading)))
    })

    this.assembleOutline(entries)
    this.updateCommentBadges()
  }

  // ProseMirror owns every node under its root. The reader's heading IDs,
  // title spans and permalink links cannot be inserted there: its next DOM
  // reconciliation would discard them and could move the caret. Keep the
  // outline as a read-only projection of the editor document instead.
  buildEditorToc(root) {
    // Keep the column fixed for this edit session. Removing or adding the
    // last heading must not move the caret or a toolbar button mid-click.
    if (this._editorRoot !== root) this._editorSidebarDisplayed = this.sidebarTarget.style.display !== "none"
    this._editorRoot = root
    this._headings = this.editorHeadings()
    this._editorHeadingSignature = this.editorHeadingSignature(this._headings)
    this._outlineIds = []
    this._itemsById = new Map()
    this.sidebarTarget.style.display = this._editorSidebarDisplayed ? "" : "none"
    // The toolbar owns this action while editing. The reader's floating
    // button would cover formatting when an empty notice no longer reserves
    // a row above the editor. Hide it without giving up its width: it sizes
    // the column the title and body share, which must not jump on Edit.
    if (this.hasShowBtnTarget) this.showBtnTarget.style.visibility = "hidden"
    this.updateEditorToggle()

    const used = new Set()
    const entries = []
    this._headings.forEach((heading, index) => {
      const title = heading.textContent.trim().replace(/\s+/g, " ")
      const base = this.slugify(title) || `section-${index + 1}`
      let id = base, suffix = 2
      while (used.has(id)) id = `${base}-${suffix++}`
      used.add(id)
      this._outlineIds.push(id)

      entries.push(this.outlineEntry(id, heading.tagName, title, event => this.handleLinkClick(event, this.editorHeadings()[index], id)))
    })
    this.assembleOutline(entries)
    this.updateCommentBadges()
  }

  outlineEntry(id, tagName, text, onClick) {
    const item = document.createElement("li")
    item.className = `content-nav__item content-nav__item--${tagName.toLowerCase()}`
    item.dataset.headingId = id
    const row = document.createElement("div")
    row.className = "content-nav__row"
    const link = document.createElement("a")
    link.className = "content-nav__link"
    link.href = `#${id}`
    const label = document.createElement("span")
    label.className = "content-nav__link-text"
    label.textContent = text
    link.append(label)
    link.addEventListener("click", onClick)
    row.append(link)
    item.append(row)
    this._itemsById.set(id, item)
    return { id, level: Number(tagName[1]), text, item, row, children: [] }
  }

  // Nest each heading under the nearest shallower one before it. Rebuilds
  // (live updates, editor typing) carry each subtree's state over by id,
  // the reader's remembered toggle, heading text, then outline position —
  // typing in a heading changes both its editor id and its text.
  assembleOutline(entries) {
    const previousById = this._expanded || new Map()
    const previousByText = new Map()
    const previousByPosition = new Map()
    previousById.forEach((expanded, id) => {
      previousByText.set(this._textById.get(id), expanded)
      previousByPosition.set(this._positionById.get(id), expanded)
    })
    const stored = this.storedOutlineState()
    this._expanded = new Map()
    this._textById = new Map()
    this._positionById = new Map()
    this._parentById = new Map()
    this._childIds = new Map()

    const roots = []
    const stack = []
    entries.forEach((entry, index) => {
      this._textById.set(entry.id, entry.text)
      this._positionById.set(entry.id, `${index}:${entry.level}`)
      while (stack.length && stack.at(-1).level >= entry.level) stack.pop()
      const parent = stack.at(-1)
      if (parent) {
        parent.children.push(entry)
        this._parentById.set(entry.id, parent.id)
      } else roots.push(entry)
      stack.push(entry)
    })

    // A lone root (usually the document title) holds the whole outline;
    // folding it would leave a single line.
    const collapsible = entries.length > COLLAPSE_THRESHOLD
    const foldable = entry => collapsible && entry.children.length > 0 && !(roots.length === 1 && entry === roots[0])
    const anyFoldable = entries.some(foldable)
    // A section that first becomes foldable in a rebuild (say the outline
    // grows past the threshold) must not fold away the reader's position.
    const activeAncestors = new Set()
    for (let parent = this._parentById.get(this._revealedActiveId); parent; parent = this._parentById.get(parent)) activeAncestors.add(parent)

    const place = (entry, list) => {
      list.append(entry.item)
      this._childIds.set(entry.id, entry.children.map(child => child.id))
      if (!entry.children.length) {
        if (anyFoldable) entry.row.prepend(Object.assign(document.createElement("span"), { className: "content-nav__disclosure-spacer" }))
        return
      }
      const group = document.createElement("ul")
      group.className = "content-nav__children"
      group.id = `content-nav-group-${entry.id}`
      entry.item.append(group)
      entry.children.forEach(child => place(child, group))
      if (!foldable(entry)) return

      const button = document.createElement("button")
      button.type = "button"
      button.className = "content-nav__disclosure"
      button.setAttribute("aria-controls", group.id)
      button.setAttribute("aria-label", `${entry.text} sub-sections`)
      button.dataset.action = "coplan--content-nav#toggleSection"
      button.innerHTML = CHEVRON
      entry.row.prepend(button)
      const remembered = typeof stored[entry.id] === "boolean" ? stored[entry.id] : undefined
      this._expanded.set(entry.id, previousById.get(entry.id) ?? remembered ?? previousByText.get(entry.text) ??
        previousByPosition.get(this._positionById.get(entry.id)) ?? activeAncestors.has(entry.id))
      this.renderExpanded(entry.id)
    }
    this.listTarget.replaceChildren()
    roots.forEach(root => place(root, this.listTarget))
    if (this.hasTreeControlsTarget) this.treeControlsTarget.hidden = this._expanded.size === 0
  }

  renderExpanded(id) {
    const item = this._itemsById.get(id)
    const expanded = this._expanded.get(id)
    const button = item.querySelector(":scope > .content-nav__row > .content-nav__disclosure")
    button.setAttribute("aria-expanded", String(expanded))
    button.title = expanded ? "Collapse" : "Expand"
    item.querySelector(":scope > .content-nav__children").hidden = !expanded
  }

  // Only `remember` (a reader's own toggle) reaches sessionStorage;
  // following the scroll position or a link is not a preference.
  setExpanded(ids, expanded, { remember = false } = {}) {
    if (!this._expanded) return
    const state = remember ? this.storedOutlineState() : null
    let changed = false
    ids.forEach(id => {
      if (!this._expanded.has(id)) return
      if (state) state[id] = expanded
      if (this._expanded.get(id) === expanded) return
      this._expanded.set(id, expanded)
      this.renderExpanded(id)
      changed = true
    })
    if (state) this.storeOutlineState(state)
    if (changed) this.renderBadges()
  }

  revealEntry(id, { includeSelf = false } = {}) {
    const ids = includeSelf ? [ id ] : []
    for (let parent = this._parentById?.get(id); parent; parent = this._parentById.get(parent)) ids.push(parent)
    this.setExpanded(ids, true)
  }

  revealHashTarget() {
    let id
    try { id = decodeURIComponent(window.location.hash.slice(1)) } catch { return }
    if (id && this._itemsById?.has(id)) this.revealEntry(id, { includeSelf: true })
  }

  toggleSection(event) {
    const id = event.currentTarget.closest(".content-nav__item").dataset.headingId
    this.setExpanded([ id ], !this._expanded.get(id), { remember: true })
  }

  expandAll() {
    this.setExpanded([ ...this._expanded.keys() ], true, { remember: true })
  }

  collapseAll() {
    this.setExpanded([ ...this._expanded.keys() ], false, { remember: true })
  }

  // Tree-view keys on a focused entry of a collapsible outline: Right opens
  // a folded subtree, then moves into it; Left folds an open one, then
  // moves to the parent.
  outlineKeydown(event) {
    if (!["ArrowLeft", "ArrowRight"].includes(event.key) || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return
    if (!this._expanded?.size) return
    const id = event.target.closest(".content-nav__item")?.dataset.headingId
    if (!id || !this._itemsById.has(id)) return
    const expanded = this._expanded.get(id)
    const children = this._childIds.get(id) || []
    let focusId = null
    if (event.key === "ArrowRight") {
      if (expanded === false) this.setExpanded([ id ], true, { remember: true })
      else if (children.length) focusId = children[0]
      else return
    } else if (expanded === true) {
      this.setExpanded([ id ], false, { remember: true })
    } else {
      focusId = this._parentById.get(id)
      if (!focusId) return
    }
    event.preventDefault()
    event.stopPropagation()
    if (focusId) this._itemsById.get(focusId).querySelector(":scope > .content-nav__row > .content-nav__link").focus()
  }

  hashChanged() {
    this.revealHashTarget()
  }

  outlineStateKey() {
    return OUTLINE_STATE_PREFIX + (this.planIdValue || window.location.pathname)
  }

  // Keys for headings that no longer exist are simply never looked up.
  storedOutlineState() {
    try {
      const state = JSON.parse(sessionStorage.getItem(this.outlineStateKey()))
      return state && typeof state === "object" && !Array.isArray(state) ? state : {}
    } catch {
      return {}
    }
  }

  storeOutlineState(state) {
    try { sessionStorage.setItem(this.outlineStateKey(), JSON.stringify(state)) } catch { /* storage unavailable */ }
  }

  // The entry a reader can see for `id`: itself, or the outermost folded
  // ancestor hiding it.
  visibleItem(id) {
    let visible = id
    for (let parent = this._parentById?.get(id); parent; parent = this._parentById.get(parent)) {
      if (this._expanded.get(parent) === false) visible = parent
    }
    return this._itemsById?.get(visible)
  }

  editorHeadings() {
    return Array.from(this._editorRoot?.querySelectorAll(":scope > h1, :scope > h2, :scope > h3") || [])
  }

  editorHeadingSignature(headings) {
    return headings.map(heading => `${heading.tagName}:${heading.textContent}`).join("\0")
  }

  editorContentChanged() {
    clearTimeout(this._editorTocTimer)
    this._editorTocTimer = setTimeout(() => {
      if (this._editorRoot && this.editorHeadingSignature(this.editorHeadings()) !== this._editorHeadingSignature) {
        this.editorModeChanged()
      }
    }, 120)
  }

  slugify(text) {
    return text
      .toLowerCase()
      .replace(/\s+/g, "-")
      .replace(/[^a-z0-9-]/g, "")
      .replace(/-{2,}/g, "-")
      .replace(/^-|-$/g, "")
  }

  setupScrollTracking() {
    if (this._scrollHandler) {
      window.removeEventListener("scroll", this._scrollHandler)
    }
    if (!this._headings || this._headings.length === 0) return

    this._scrollHandler = () => {
      if (this._ignoreScroll) {
        clearTimeout(this._scrollEndTimer)
        this._scrollEndTimer = setTimeout(() => {
          this._ignoreScroll = false
        }, 100)
        return
      }
      if (!this._scrollTicking) {
        requestAnimationFrame(() => {
          this._updateActiveFromScroll()
          this._scrollTicking = false
        })
        this._scrollTicking = true
      }
    }
    window.addEventListener("scroll", this._scrollHandler, { passive: true })
    this._updateActiveFromScroll()
  }

  contentUpdated(event) {
    // Footnote counts and citation lists also receive live stream swaps.
    // They do not change document headings, and rebuilding the outline for
    // them would erase a recent remote-change cue.
    if (!this.contentTarget.querySelector("#plan-content-body")?.contains(event?.target)) return
    this._activeHeadingId = null
    this.buildToc()
    this.setupScrollTracking()
  }

  editorModeChanged() {
    this._activeHeadingId = null
    this.buildToc()
    this.setupScrollTracking()
  }

  remoteChange(event) {
    for (const key of event.detail.keys || []) {
      // A change inside a folded subtree pulses the entry that hides it.
      const item = this.visibleItem(key)
      if (!item) continue
      item.classList.remove("content-nav__item--remote-change")
      // Restart the pulse when consecutive revisions touch one section.
      void item.offsetWidth
      item.classList.add("content-nav__item--remote-change")
      clearTimeout(item._remoteChangeTimer)
      item._remoteChangeTimer = setTimeout(() => item.classList.remove("content-nav__item--remote-change"), 2600)
    }
  }

  slideChanged() {
    requestAnimationFrame(() => this._updateActiveFromScroll())
  }

  _updateActiveFromScroll() {
    const threshold = 100
    let active = null
    const headings = this._editorRoot ? this.editorHeadings() : this._headings.filter(heading => {
      const slide = heading.closest(".deck-slide")
      return !slide || slide.classList.contains("deck-slide--current")
    })
    for (const heading of headings) {
      if (heading.getBoundingClientRect().top <= threshold) {
        active = heading
      } else {
        break
      }
    }

    const index = headings.indexOf(active)
    const id = this._editorRoot ? this._outlineIds[Math.max(index, 0)] : active?.id || headings[0]?.id
    if (id && id !== this._activeHeadingId) {
      this._activeHeadingId = id
      // Unfold the active entry's ancestors once per section reached. A
      // rebuild must not reopen a subtree the reader folded around it.
      if (id !== this._revealedActiveId) {
        this._revealedActiveId = id
        this.revealEntry(id)
      }
      this._setActiveLink(id)
    }
  }

  handleLinkClick(event, heading, outlineId = heading?.id) {
    event.preventDefault()
    if (!heading) return
    this.closeOutlinePopover()
    history.replaceState(null, "", `#${outlineId}`)

    this._ignoreScroll = true
    this._activeHeadingId = outlineId
    this._setActiveLink(outlineId)

    this._revealDeckSlide(heading)
    heading.scrollIntoView({ behavior: "smooth", block: "start" })
  }

  async copySectionLink(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    event.preventDefault()
    const link = event.currentTarget

    try {
      await navigator.clipboard.writeText(link.href)
      this.flashSectionLink(link, "copied", "Copied link to section")
    } catch {
      this.flashSectionLink(link, "failed", "Copy failed")
    }
  }

  flashSectionLink(link, state, label) {
    link.dataset.copyState = state
    link.dataset.copyMessage = state === "copied" ? "Copied!" : "Copy failed"
    link.setAttribute("aria-label", label)
    link.title = label

    clearTimeout(link._copyResetTimer)
    link._copyResetTimer = setTimeout(() => {
      link.removeAttribute("data-copy-state")
      link.removeAttribute("data-copy-message")
      link.setAttribute("aria-label", `Copy link to ${link.dataset.sectionTitle}`)
      link.title = "Copy link to this section"
    }, 2000)
  }

  // The back-matter links (References, Attachments) jump the same way the
  // outline above does. Turbo counts a same-page fragment link as a full
  // visit — it refetches and re-renders the page — so the bare anchor read
  // as a reload, and the scroll it performed landed against a layout that
  // async rendering (Mermaid, highlighting, deck slides) had not settled
  // yet. Scrolling in place needs neither.
  jumpToSection(event) {
    const id = event.currentTarget.getAttribute("href")?.replace(/^#/, "")
    const target = id && document.getElementById(id)
    if (!target) return

    event.preventDefault()
    this.closeOutlinePopover()
    history.replaceState(null, "", `#${id}`)

    this._ignoreScroll = true
    target.querySelector("details.document-support__disclosure")?.setAttribute("open", "")
    this._revealDeckSlide(target)
    target.scrollIntoView({ behavior: "smooth", block: "start" })
    target.focus({ preventScroll: true })
  }

  _revealDeckSlide(element) {
    const slide = element.closest(".deck-region .deck-slide")
    if (slide) slide.dispatchEvent(new CustomEvent("coplan:deck-reveal", {
      bubbles: true, detail: { slide: slide.dataset.slide }
    }))
  }

  _setActiveLink(id) {
    this.listTarget.querySelectorAll(".content-nav__link").forEach(link => {
      link.classList.remove("content-nav__link--active")
    })

    const item = this._itemsById?.get(id)
    const link = item?.querySelector(".content-nav__link")
    if (link) {
      link.classList.add("content-nav__link--active")
      link.scrollIntoView({ block: "nearest" })
    }
  }

  toggle() {
    if (this.sidebarTarget.hasAttribute("popover")) {
      if (this.sidebarTarget.matches(":popover-open")) this.closeOutlinePopover()
      else this.showOutline()
      return
    }
    if (this._editorRoot && !this._editorSidebarDisplayed && this._headings.length) {
      // The first heading does not open a column mid-typing. An explicit
      // outline request can still reveal it during the edit session.
      this.showOutline()
    } else this.visibleValue = !this.visibleValue
    this.updateEditorToggle()
    localStorage.setItem(STORAGE_KEY, this.visibleValue)
  }

  showOutline(event) {
    if (this._editorRoot) this._editorSidebarDisplayed = true
    this.sidebarTarget.style.display = ""
    if (this.hasShowBtnTarget) this.showBtnTarget.style.display = this._editorRoot ? "none" : ""
    this.visibleValue = true
    this.visibleValueChanged()
    localStorage.setItem(STORAGE_KEY, true)
    if (window.matchMedia("(max-width: 1024px)").matches) {
      this._outlineTrigger = event?.detail?.trigger || document.activeElement
      this.sidebarTarget.setAttribute("popover", "auto")
      this.sidebarTarget.showPopover()
      this.toggleBtnTarget.focus({ preventScroll: true })
    }
  }

  closeOutlinePopover() {
    if (this.sidebarTarget.hasAttribute("popover") && this.sidebarTarget.matches(":popover-open")) this.sidebarTarget.hidePopover()
  }

  outlineClosing(event) {
    if (event.newState === "closed" && this.sidebarTarget.contains(document.activeElement)) {
      this._outlineTrigger?.focus({ preventScroll: true })
    }
  }

  outlineResized() {
    if (!window.matchMedia("(max-width: 1024px)").matches && this.sidebarTarget.hasAttribute("popover")) {
      this.closeOutlinePopover()
      this.sidebarTarget.removeAttribute("popover")
    }
  }

  visibleValueChanged() {
    if (!this.hasSidebarTarget) return

    const hidden = !this.visibleValue
    this.sidebarTarget.classList.toggle("content-nav--hidden", hidden)
    this.sidebarTarget.setAttribute("aria-hidden", String(hidden))
    if (hidden) {
      this.sidebarTarget.setAttribute("inert", "")
    } else {
      this.sidebarTarget.removeAttribute("inert")
    }

    if (this.hasToggleBtnTarget) {
      this.toggleBtnTarget.setAttribute("aria-expanded", String(this.visibleValue))
    }
    this.updateEditorToggle()
  }

  updateEditorToggle() {
    if (!this.hasEditorToggleBtnTarget) return
    this.editorToggleBtnTarget.disabled = !this._headings?.length
    this.editorToggleBtnTarget.setAttribute("aria-expanded", String(Boolean(this._editorSidebarDisplayed && this.visibleValue)))
  }

  handleKeydown(event) {
    // "t" as in table of contents — [ and ] belong to section jumps
    // (coplan--plan-keys).
    if (commandFor("outline", event) === "toggle") {
      event.preventDefault()
      this.toggle()
    }
  }

  updateCommentBadges() {
    if (!this._headings || this._headings.length === 0) return

    const container = this._editorRoot || this.contentTarget
    if (!container.querySelector(".markdown-rendered") && !container.classList.contains("markdown-rendered")) return

    // Walk the whole content column: on a deck, consecutive outline
    // headings live in different slides, so the span between two of them
    // crosses .markdown-rendered blocks.
    const headings = this._editorRoot ? this.editorHeadings() : this._headings
    this._ownCounts = new Map()
    headings.forEach((heading, index) => {
      const id = this._editorRoot ? this._outlineIds[index] : heading.id
      this._ownCounts.set(id, this.countOpenThreadsBetween(heading, headings[index + 1], container))
    })
    this.renderBadges()
  }

  // A folded entry adds its hidden sub-sections' counts to its own.
  renderBadges() {
    if (!this._ownCounts || !this._itemsById) return
    this._itemsById.forEach((item, id) => {
      const link = item.querySelector(":scope > .content-nav__row > .content-nav__link")
      link.querySelector(".content-nav__badge")?.remove()
      const hidden = this._expanded?.get(id) === false ? this.descendantCount(id) : 0
      const count = (this._ownCounts.get(id) || 0) + hidden
      if (count === 0) return

      const badge = document.createElement("span")
      badge.className = "content-nav__badge content-nav__badge--open"
      badge.textContent = count
      if (hidden) badge.title = `${count} open discussion${count === 1 ? "" : "s"}, including collapsed sub-sections`
      link.appendChild(badge)
    })
  }

  descendantCount(id) {
    return (this._childIds.get(id) || []).reduce((sum, child) => sum + (this._ownCounts.get(child) || 0) + this.descendantCount(child), 0)
  }

  countOpenThreadsBetween(startHeading, endHeading, container) {
    const seen = new Set()
    let collecting = false
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_ELEMENT, null)

    let node
    while ((node = walker.nextNode())) {
      if (node === startHeading) {
        collecting = true
        continue
      }
      if (endHeading && node === endHeading) break

      if (collecting && node.tagName === "MARK" && node.classList.contains("anchor-highlight--open")) {
        const threadId = node.dataset.threadId
        if (threadId) seen.add(threadId)
      }
    }

    return seen.size
  }
}
