import { Controller } from "@hotwired/stimulus"

const HOVER_OPEN_DELAY = 180
const HOVER_CLOSE_DELAY = 220
const SECTION_PREVIEW_LENGTH = 520

// Previews rendered footnotes and explicitly linked, numbered sections.
// The target content is already present and sanitized in the plan DOM, so
// opening a preview is instant and never depends on another request.
export default class extends Controller {
  static targets = ["popover", "title", "body"]

  connect() {
    this.mode = null
    this.activeAnchor = null
  }

  disconnect() {
    this.cancelOpen()
    this.cancelClose()
  }

  // A held button means the reader is sweeping a selection across the line,
  // not resting on a reference — a card that opens mid-drag covers the very
  // text they are trying to select and comment on. Each entry point reads
  // that for itself, so there is no flag to leave stranded when a gesture
  // ends without a mouseup (a link drag, a release outside the window):
  // mouseenter carries the button state, and the focus Chromium fires on
  // mousedown answers with :focus-visible, which a press never matches but
  // keyboard and assistive-technology focus always do.
  enter(event) {
    const anchor = event.currentTarget
    if (!this.targetFor(anchor)) return
    if (event.type === "mouseenter" && event.buttons !== 0) return

    const focused = event.type === "focus"
    this.cancelOpen()
    this.cancelClose()
    this.openTimer = setTimeout(() => {
      // Asked as the card is about to open, not while the focus event is
      // still dispatching: Chrome settles :focus-visible afterwards, so
      // reading it inside the handler races and intermittently turns a
      // keyboard reader away.
      if (focused && !anchor.matches(":focus-visible")) return
      this.show(anchor, "hover")
    }, HOVER_OPEN_DELAY)
  }

  leave() {
    this.cancelOpen()
    if (this.mode === "hover") this.scheduleClose()
  }

  popoverEnter() {
    this.cancelClose()
  }

  popoverLeave() {
    if (this.mode === "hover") this.scheduleClose()
  }

  dismissFromOutside(event) {
    if (!this.isOpen()) return
    if (this.popoverTarget.contains(event.target)) return
    if (this.activeAnchor?.contains(event.target)) return

    this.dismiss()
  }

  dismiss(event) {
    const returnFocus = event?.type === "keydown" || event?.currentTarget?.classList?.contains("reference-preview__close")
    const anchor = this.activeAnchor
    this.cancelOpen()
    this.cancelClose()
    this.hide()
    if (returnFocus && anchor?.isConnected) anchor.focus({ preventScroll: true })
  }

  // Preserve ordinary hash-link behavior even while dismissing the preview.
  // Turbo does not consistently navigate same-document fragments after the
  // hover card changes state during the click, so perform the jump directly.
  // A live selection deliberately does NOT veto the jump. It cannot mean
  // "this click is the tail of a sweep": the browser dispatches a sweep's
  // click on the common ancestor paragraph rather than the anchor, and
  // refuses to start a selection from a press on a link at all. So a
  // selection here always predates the press, the click is always
  // deliberate, and swallowing it strands the reader — clicking a link
  // never collapses a selection, so every retry would be swallowed too.
  follow(event) {
    const href = event.currentTarget.getAttribute("href")
    const target = this.targetFor(event.currentTarget)
    this.cancelOpen()
    this.cancelClose()
    this.hide()
    if (!target || !href?.startsWith("#")) return

    event.preventDefault()
    window.location.hash = href
    target.scrollIntoView()
  }

  reposition() {
    if (this.isOpen() && this.activeAnchor?.isConnected) {
      this.positionAt(this.activeAnchor)
    }
  }

  show(anchor, mode) {
    const target = this.targetFor(anchor)
    if (!target) return

    this.renderPreview(anchor, target)
    this.setActiveAnchor(anchor)
    this.mode = mode

    const popover = this.popoverTarget
    popover.style.visibility = "hidden"
    if (!this.isOpen()) {
      if (typeof popover.showPopover === "function") {
        try { popover.showPopover() } catch {}
      } else {
        popover.classList.add("reference-preview--open")
      }
    }
    this.positionAt(anchor)
    popover.style.visibility = "visible"
  }

  hide() {
    if (this.hasPopoverTarget) {
      if (typeof this.popoverTarget.hidePopover === "function") {
        try { this.popoverTarget.hidePopover() } catch {}
      }
      this.popoverTarget.classList.remove("reference-preview--open", "reference-preview--sheet")
      this.popoverTarget.style.visibility = ""
    }

    if (this.activeAnchor) this.activeAnchor.setAttribute("aria-expanded", "false")
    this.activeAnchor = null
    this.mode = null
  }

  renderPreview(anchor, target) {
    const footnote = anchor.classList.contains("reference-anchor--footnote")
    const title = target.textContent.trim()
    this.titleTarget.hidden = footnote
    this.titleTarget.textContent = footnote ? "" : title
    this.popoverTarget.setAttribute("aria-label", footnote ? "Citation preview" : `Section preview: ${title}`)

    if (footnote) {
      this.renderFootnote(target)
    } else {
      this.renderSection(target)
    }
  }

  renderFootnote(target) {
    const fragment = document.createDocumentFragment()
    Array.from(target.childNodes).forEach(node => fragment.appendChild(node.cloneNode(true)))

    const wrapper = document.createElement("div")
    wrapper.appendChild(fragment)
    wrapper.querySelectorAll("[id]").forEach(node => node.removeAttribute("id"))
    wrapper.querySelectorAll("[data-action], [data-controller]").forEach(node => {
      node.removeAttribute("data-action")
      node.removeAttribute("data-controller")
    })
    wrapper.querySelectorAll("a[data-footnote-backref]").forEach(node => node.remove())
    wrapper.querySelectorAll('input[type="checkbox"]').forEach(node => node.setAttribute("disabled", ""))

    const externalLinks = Array.from(wrapper.querySelectorAll('a[target="_blank"]'))
    externalLinks.forEach(node => {
      if (node.classList.contains("citation-source--block")) {
        node.classList.add("reference-preview__source")
        return
      }

      const originalText = node.textContent.trim()
      const url = new URL(node.href)
      const domain = url.hostname.replace(/^www\./, "")
      const type = this.referenceTypeLabel(node.dataset.referenceType, url)

      const title = document.createElement("span")
      title.className = "reference-preview__source-title"
      title.textContent = originalText || domain

      const metadata = document.createElement("span")
      metadata.className = "reference-preview__source-meta"
      metadata.textContent = `${type} · ${domain} ↗`

      node.classList.add("reference-preview__source")
      node.setAttribute("aria-label", `Open source: ${originalText || domain} in a new tab (${type}, ${domain})`)
      node.replaceChildren(title, metadata)

      const punctuation = node.nextSibling
      if (punctuation?.nodeType === Node.TEXT_NODE && /^\s*[.,;:]\s*$/.test(punctuation.textContent)) punctuation.remove()
    })

    this.bodyTarget.replaceChildren(...Array.from(wrapper.childNodes))
  }

  referenceTypeLabel(referenceType, url) {
    if (referenceType === "plan") return "CoPlan plan"
    if (referenceType === "repository") return "GitHub repository"
    if (referenceType === "pull_request") return "GitHub pull request"

    if (referenceType === "document") {
      if (url.hostname === "docs.google.com") {
        if (url.pathname.startsWith("/spreadsheets/")) return "Google Sheet"
        if (url.pathname.startsWith("/presentation/")) return "Google Slides"
        return "Google Doc"
      }
      if (url.hostname === "drive.google.com") return "Google Drive"
      if (url.hostname.endsWith("notion.so") || url.hostname.endsWith("notion.site")) return "Notion"
      if (url.hostname.includes("confluence")) return "Confluence"
      return "Document"
    }

    return /(^|\.)gov(\.|$)/.test(url.hostname) ? "Government website" : "Website"
  }

  renderSection(heading) {
    const level = Number(heading.tagName.slice(1))
    const parts = []
    let node = heading.nextElementSibling

    while (node) {
      if (node.matches("[data-footnotes]")) break
      if (/^H[1-6]$/.test(node.tagName) && Number(node.tagName.slice(1)) <= level) break

      const text = node.textContent.replace(/\s+/g, " ").trim()
      if (text) parts.push(text)
      if (parts.join(" ").length >= SECTION_PREVIEW_LENGTH) break
      node = node.nextElementSibling
    }

    let text = parts.join(" ")
    if (text.length > SECTION_PREVIEW_LENGTH) {
      text = `${text.slice(0, SECTION_PREVIEW_LENGTH - 1).trimEnd()}…`
    }

    const paragraph = document.createElement("p")
    paragraph.textContent = text || "This section has no preview text."
    this.bodyTarget.replaceChildren(paragraph)
  }

  targetFor(anchor) {
    const href = anchor?.getAttribute("href")
    if (!href?.startsWith("#") || href.length === 1) return null

    try {
      return document.getElementById(decodeURIComponent(href.slice(1)))
    } catch {
      return null
    }
  }

  setActiveAnchor(anchor) {
    if (this.activeAnchor && this.activeAnchor !== anchor) {
      this.activeAnchor.setAttribute("aria-expanded", "false")
    }
    this.activeAnchor = anchor
    anchor.setAttribute("aria-expanded", "true")
  }

  positionAt(anchor) {
    const popover = this.popoverTarget
    if (window.matchMedia("(max-width: 640px)").matches) {
      popover.classList.add("reference-preview--sheet")
      popover.style.top = ""
      popover.style.left = ""
      return
    }

    popover.classList.remove("reference-preview--sheet")
    const anchorRect = anchor.getBoundingClientRect()
    const popoverRect = popover.getBoundingClientRect()
    const gap = 8

    let top = anchorRect.bottom + gap
    let left = anchorRect.left
    if (top + popoverRect.height > window.innerHeight - 16) {
      top = anchorRect.top - popoverRect.height - gap
    }
    if (left + popoverRect.width > window.innerWidth - 16) {
      left = window.innerWidth - popoverRect.width - 16
    }

    popover.style.top = `${Math.max(16, top)}px`
    popover.style.left = `${Math.max(16, left)}px`
  }

  scheduleClose() {
    this.cancelClose()
    this.closeTimer = setTimeout(() => this.hide(), HOVER_CLOSE_DELAY)
  }

  cancelOpen() {
    if (this.openTimer) clearTimeout(this.openTimer)
    this.openTimer = null
  }

  cancelClose() {
    if (this.closeTimer) clearTimeout(this.closeTimer)
    this.closeTimer = null
  }

  isOpen() {
    if (!this.hasPopoverTarget) return false
    if (this.popoverTarget.classList.contains("reference-preview--open")) return true

    try {
      return this.popoverTarget.matches(":popover-open")
    } catch {
      return false
    }
  }
}
