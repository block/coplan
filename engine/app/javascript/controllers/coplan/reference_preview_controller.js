import { Controller } from "@hotwired/stimulus"

const HOVER_OPEN_DELAY = 180
const HOVER_CLOSE_DELAY = 220
const SECTION_PREVIEW_LENGTH = 520

// Previews rendered footnotes and explicitly linked, numbered sections.
// The target content is already present and sanitized in the plan DOM, so
// opening a preview is instant and never depends on another request.
export default class extends Controller {
  static targets = ["popover", "label", "title", "body", "jump"]

  connect() {
    this.mode = null
    this.activeAnchor = null
  }

  disconnect() {
    this.cancelOpen()
    this.cancelClose()
  }

  enter(event) {
    const anchor = event.currentTarget
    if (!this.targetFor(anchor)) return
    if (this.mode === "pinned") return

    this.cancelOpen()
    this.cancelClose()
    this.openTimer = setTimeout(() => this.show(anchor, "hover"), HOVER_OPEN_DELAY)
  }

  leave() {
    this.cancelOpen()
    if (this.mode === "hover") this.scheduleClose()
  }

  pin(event) {
    const anchor = event.currentTarget
    if (!this.targetFor(anchor)) return

    event.preventDefault()
    this.cancelOpen()
    this.cancelClose()
    this.show(anchor, "pinned")
    if (event.detail === 0) this.jumpTarget.focus({ preventScroll: true })
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

  follow() {
    this.hide()
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
    this.labelTarget.textContent = footnote ? "Citation" : "Internal reference"
    this.titleTarget.textContent = footnote ? `Reference ${anchor.textContent.trim()}` : target.textContent.trim()
    this.jumpTarget.href = anchor.getAttribute("href")
    this.jumpTarget.textContent = footnote ? "Go to citation" : "Go to section"

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

    this.bodyTarget.replaceChildren(...Array.from(wrapper.childNodes))
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
