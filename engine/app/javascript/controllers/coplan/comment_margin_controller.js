import { Controller } from "@hotwired/stimulus"

// Collapsed discussion markers in the page margin, one per highlighted
// thread, aligned with the text they discuss. A marker shows the first
// commenter's avatar; clicking it opens the same discussion window as
// clicking the highlight.
//
// Cards are derived from the highlights coplan--text-selection builds and
// from the thread popovers in #plan-threads, so broadcasts that add
// threads or comments update them without a server round-trip.
const STACK_GAP = 4
// Room beside the document card: gap from the card, gap from the window
// edge, and the marker width.
const GAP = 12
const EDGE = 8
const WIDTH = 30
// Lucide message-circle, copyright 2026 Lucide Icons, ISC license.
const COMMENT_ICON = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"/></svg>'

export default class extends Controller {
  connect() {
    this.layout = this.element.closest(".plan-layout")
    this.content = this.layout.querySelector("[data-coplan--text-selection-target~='content']")
    this.cards = new Map()

    // Comment appends, edits, and deletes change a thread's summary without
    // re-running highlightAnchors.
    const threads = this.layout.querySelector("#plan-threads")
    if (threads) {
      this.threadsObserver = new MutationObserver(() => this.scheduleRefresh())
      this.threadsObserver.observe(threads, { childList: true, subtree: true })
    }
    // Images, diagrams, and expanded rows move the text after highlighting.
    this.resizeObserver = new ResizeObserver(() => this.position())
    this.resizeObserver.observe(this.content)
    this.refresh()
  }

  disconnect() {
    this.threadsObserver?.disconnect()
    this.resizeObserver?.disconnect()
    cancelAnimationFrame(this.refreshFrame)
  }

  scheduleRefresh() {
    cancelAnimationFrame(this.refreshFrame)
    this.refreshFrame = requestAnimationFrame(() => this.refresh())
  }

  refresh() {
    const showResolved = !this.layout.classList.contains("plan-layout--hide-resolved")
    const marks = new Map()
    for (const mark of this.content.querySelectorAll("mark.anchor-highlight[data-thread-id]")) {
      const id = mark.dataset.threadId
      if (marks.has(id) || !mark.getClientRects().length) continue
      if (!showResolved && !mark.classList.contains("anchor-highlight--open")) continue
      marks.set(id, mark)
    }

    for (const [id, card] of this.cards) {
      if (marks.has(id)) continue
      card.remove()
      this.cards.delete(id)
    }
    for (const [id, mark] of marks) {
      const popover = document.getElementById(`${id}_popover`)
      if (!popover) continue
      const card = this.cards.get(id) || this.buildCard(id)
      this.fillCard(card, popover, mark)
    }

    this.marks = marks
    this.element.hidden = this.cards.size === 0
    this.position()
  }

  // Reuse card elements: an open discussion window tracks its trigger
  // element while the page scrolls.
  buildCard(id) {
    const card = document.createElement("button")
    card.type = "button"
    card.className = "comment-margin__card"
    card.dataset.threadId = id
    card.dataset.action = "click->coplan--text-selection#openThreadPopover"
    this.element.append(card)
    this.cards.set(id, card)
    return card
  }

  // A card shows only the first commenter's avatar; the name and reply count
  // are for assistive technology.
  fillCard(card, popover, mark) {
    const comments = popover.querySelectorAll(".thread-popover__comments > .comment:not(.comment--deleted)")
    const header = comments[0]?.querySelector(".comment__header")
    const avatar = header?.querySelector(".avatar, .comment__agent-avatar")?.cloneNode(true)
    const author = header?.querySelector("strong")?.textContent.trim()
    const replies = comments.length - 1
    const resolved = !mark.classList.contains("anchor-highlight--open")
    const signature = [author, replies, resolved, avatar?.outerHTML].join("\u0000")
    if (card.dataset.signature === signature) return
    card.dataset.signature = signature

    card.classList.toggle("comment-margin__card--resolved", resolved)
    if (avatar) {
      avatar.removeAttribute("title")
      avatar.setAttribute("aria-hidden", "true")
      card.replaceChildren(avatar)
    } else {
      card.innerHTML = COMMENT_ICON
    }
    const label = [author ? `Discussion started by ${author}` : "Discussion"]
    if (replies > 0) label.push(`${replies} ${replies === 1 ? "reply" : "replies"}`)
    card.setAttribute("aria-label", label.join(", "))
  }

  // Place the column in the page margin right of the document card, then
  // align each card with its highlight, pushing later cards down so they
  // never overlap.
  position() {
    if (!this.marks || this.element.hidden) return
    const layoutRect = this.layout.getBoundingClientRect()
    const cardRight = (this.layout.closest(".plan-document") || this.layout).getBoundingClientRect().right
    const fits = document.documentElement.clientWidth - cardRight - GAP - EDGE >= WIDTH
    this.element.toggleAttribute("data-fits", fits)
    if (!fits) return
    this.element.style.left = `${cardRight + GAP - layoutRect.left}px`

    const originTop = this.element.getBoundingClientRect().top
    const placed = []
    for (const [id, mark] of this.marks) {
      const card = this.cards.get(id)
      const rect = mark.getClientRects()[0]
      if (!card || !rect) continue
      placed.push({ card, top: rect.top + (rect.height - WIDTH) / 2 - originTop })
    }
    placed.sort((a, b) => a.top - b.top)
    let floor = 0
    for (const { card, top } of placed) {
      const y = Math.max(top, floor)
      card.style.top = `${y}px`
      floor = y + card.offsetHeight + STACK_GAP
    }
  }

  // Hovering a marker or any fragment of its highlight lights up both.
  // Highlights are rebuilt by coplan--text-selection, so hover is tracked
  // with one delegated document listener instead of per-mark bindings.
  hoverChanged(event) {
    const target = event.target.closest?.(".comment-margin__card, mark.anchor-highlight[data-thread-id]")
    const inScope = target && (this.element.contains(target) || this.content.contains(target))
    const id = inScope && this.cards.has(target.dataset.threadId) ? target.dataset.threadId : null
    if (id === this.hoveredId) return
    this.setHover(this.hoveredId, false)
    this.hoveredId = id
    this.setHover(id, true)
  }

  setHover(id, on) {
    if (!id) return
    this.cards.get(id)?.classList.toggle("is-hover", on)
    this.content.querySelectorAll(`mark.anchor-highlight[data-thread-id="${id}"]`)
      .forEach(mark => mark.classList.toggle("is-margin-hover", on))
  }

  // Keep the card for the open discussion visibly selected, however it was
  // opened (card, highlight, j/k, or a deep link).
  popoverToggled(event) {
    const popover = event.target
    if (!popover.classList?.contains("thread-popover")) return
    const card = this.cards.get(popover.id.replace(/_popover$/, ""))
    card?.classList.toggle("is-active", event.newState === "open")
  }
}
