import { Controller } from "@hotwired/stimulus"
import { hidingSection } from "coplan/collapsed_sections"
import { commentMarginMode } from "coplan/comment_margin"
import { marginCardWindowTop, placeOnMarginCard } from "coplan/comment_window"

// Discussions in the page margin, one per highlighted thread, aligned with
// the text they discuss. Clicking one opens the same discussion window as
// clicking the highlight.
//
// Markers mode shows a collapsed marker with the first commenter's avatar.
// Cards mode, like Google Docs, shows each discussion's first comment,
// replies, and status; the open discussion window expands over its card.
// Cards fall back to markers when the margin is too narrow for them.
//
// Cards are derived from the highlights coplan--text-selection builds and
// from the thread popovers in #plan-threads, so broadcasts that add
// threads or comments update them without a server round-trip. A closed
// <details> shows a count badge on its summary instead of markers.
const STACK_GAP = 4
// Room beside the document card: gap from the card, gap from the window
// edge, and the marker width.
const GAP = 12
const EDGE = 8
const WIDTH = 30
// Cards narrower than this would not fit a discussion window; wider margins
// stop growing at the maximum.
const CARD_MIN_WIDTH = 240
const CARD_MAX_WIDTH = 320
// Lucide message-circle, copyright 2026 Lucide Icons, ISC license.
const COMMENT_ICON = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"/></svg>'

export default class extends Controller {
  connect() {
    this.layout = this.element.closest(".plan-layout")
    this.content = this.layout.querySelector("[data-coplan--text-selection-target~='content']")
    this.cards = new Map()
    this.mode = commentMarginMode()

    // Comment appends, edits, and deletes change a thread's summary without
    // re-running highlightAnchors.
    const threads = this.layout.querySelector("#plan-threads")
    if (threads) {
      this.threadsObserver = new MutationObserver(() => this.scheduleRefresh())
      this.threadsObserver.observe(threads, { childList: true, subtree: true })
    }
    // Images, diagrams, and expanded rows move the text after highlighting;
    // an open discussion window grows the card it expands.
    this.resizeObserver = new ResizeObserver(() => this.position())
    this.resizeObserver.observe(this.content)
    this.refresh()
  }

  disconnect() {
    this.threadsObserver?.disconnect()
    this.resizeObserver?.disconnect()
    cancelAnimationFrame(this.refreshFrame)
    cancelAnimationFrame(this.positionFrame)
  }

  scheduleRefresh() {
    cancelAnimationFrame(this.refreshFrame)
    this.refreshFrame = requestAnimationFrame(() => this.refresh())
  }

  modeChanged(event) {
    this.mode = event.detail.mode
    this.position()
  }

  refresh() {
    // A broadcast that replaces a thread removes its open window without a
    // toggle event.
    if (this.activePopover && !this.activePopover.isConnected) this.activate(null, null)
    const showResolved = !this.layout.classList.contains("plan-layout--hide-resolved")
    const marks = new Map()
    const hidden = new Map()
    const seen = new Set()
    // Table-cell and diagram discussions have their own badges, so they
    // only count toward a closed section.
    for (const mark of this.content.querySelectorAll("mark.anchor-highlight[data-thread-id], [data-source-badge][data-thread-id]")) {
      const id = mark.dataset.threadId
      if (seen.has(id)) continue
      if (!showResolved && !mark.classList.contains("anchor-highlight--open")) continue
      const section = hidingSection(mark)
      if (!section && (mark.hasAttribute("data-source-badge") || !mark.getClientRects().length)) continue
      seen.add(id)
      if (section) {
        if (!hidden.has(section)) hidden.set(section, [])
        hidden.get(section).push(id)
      } else {
        marks.set(id, mark)
      }
    }
    this.renderSectionBadges(hidden)

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
    // Keep the keyboard order the same as the document order. Move only the
    // cards that are out of place, so a focused card keeps its focus.
    ;[...marks.keys()].map(id => this.cards.get(id)).filter(Boolean).forEach((card, index) => {
      const current = this.element.children[index]
      if (current !== card) this.element.insertBefore(card, current || null)
    })

    // Highlights are rebuilt on every refresh, and opening a section can
    // create the active card after its window opened; carry the linked
    // states over.
    this.setHover(this.hoveredId, true)
    this.markActive(this.activeId, true)

    this.marks = marks
    this.element.hidden = this.cards.size === 0
    if (this.element.hidden) this.report(false)
    this.measureCards = true
    this.position()
  }

  // Each closed section counts the discussions it hides, in document order;
  // its badge opens the section at the first one.
  renderSectionBadges(sections) {
    for (const badge of this.content.querySelectorAll(".details-comment-badge")) {
      if (!sections.has(badge.closest("details"))) badge.remove()
    }
    for (const [details, ids] of sections) {
      const summary = details.querySelector(":scope > summary")
      if (!summary) continue
      let badge = summary.querySelector(":scope > .details-comment-badge")
      if (!badge) {
        badge = document.createElement("button")
        badge.type = "button"
        badge.className = "details-comment-badge"
        badge.dataset.action = "click->coplan--text-selection#openSectionThread"
        // The count is CSS-generated: a text node here would enter the
        // document text that comment anchors are matched against.
        badge.innerHTML = COMMENT_ICON
        summary.append(badge)
      }
      badge.dataset.threadId = ids[0]
      badge.dataset.count = ids.length
      badge.setAttribute("aria-label", `${ids.length} ${ids.length === 1 ? "discussion" : "discussions"} in this section, open the first`)
    }
  }

  // Reuse card elements: an open discussion window tracks its trigger
  // element while the page scrolls.
  buildCard(id) {
    const card = document.createElement("button")
    card.type = "button"
    card.className = "comment-margin__card"
    card.dataset.threadId = id
    card.dataset.action = "click->coplan--text-selection#openThreadPopover"
    card.setAttribute("aria-expanded", "false")
    this.element.append(card)
    this.cards.set(id, card)
    return card
  }

  // A marker shows only the first commenter's avatar, with the name and
  // reply count for assistive technology. A card also shows the first
  // comment, the replies, and the status; its text is its accessible name.
  fillCard(card, popover, mark) {
    const comments = popover.querySelectorAll(".thread-popover__comments > .comment:not(.comment--deleted)")
    const first = this.summarize(comments[0])
    const latest = comments.length > 1 ? this.summarize(comments[comments.length - 1]) : null
    const replies = Math.max(0, comments.length - 1)
    const resolved = !mark.classList.contains("anchor-highlight--open")
    const { avatar: firstAvatar, ...firstText } = first
    const signature = JSON.stringify([firstText, latest?.author, replies, resolved])
    if (card.dataset.signature === signature) return
    card.dataset.signature = signature

    card.classList.toggle("comment-margin__card--resolved", resolved)
    const avatar = firstAvatar?.cloneNode(true)
    if (avatar) {
      avatar.removeAttribute("title")
      avatar.setAttribute("aria-hidden", "true")
    }

    const replyText = replies > 0 ? `${replies} ${replies === 1 ? "reply" : "replies"}` : ""
    const details = this.span("details", [
      this.span("head", [this.span("author", first.author || "Discussion"), this.span("time", first.time)]),
      this.span("body", first.body),
      this.span("more", "more"),
      this.span("foot", [
        this.span("replies", latest?.author ? `${replyText}, latest from ${latest.author}` : replyText),
        this.span(`status comment-margin__status--${resolved ? "resolved" : "open"}`, resolved ? "Resolved" : "Open")
      ])
    ])
    details.querySelector(".comment-margin__more").setAttribute("aria-hidden", "true")
    if (avatar) card.replaceChildren(avatar, details)
    else {
      card.innerHTML = COMMENT_ICON
      card.append(details)
    }

    const label = [first.author ? `Discussion started by ${first.author}` : "Discussion"]
    if (replies > 0) label.push(replyText)
    card.dataset.markerLabel = label.join(", ")
    this.labelCard(card)
  }

  // avatarKey stands in for the avatar in the card's change signature: its
  // class, initials, and photo address.
  summarize(comment) {
    const header = comment?.querySelector(".comment__header")
    const avatar = header?.querySelector(".avatar, .comment__agent-avatar")
    const photo = avatar?.matches("img") ? avatar : avatar?.querySelector("img")
    return {
      author: header?.querySelector("strong")?.textContent.trim() || "",
      time: header?.querySelector(".comment__meta")?.textContent.trim() || "",
      body: comment?.querySelector(".comment__body")?.textContent.replace(/\s+/g, " ").trim() || "",
      avatarKey: avatar ? [avatar.className, avatar.textContent.trim(), photo?.getAttribute("src") || ""].join("|") : "",
      avatar
    }
  }

  span(name, content) {
    const span = document.createElement("span")
    span.className = name.split(" ").map((part, index) => index === 0 ? `comment-margin__${part}` : part).join(" ")
    if (Array.isArray(content)) span.append(...content)
    else span.textContent = content
    return span
  }

  labelCard(card) {
    if (this.cardsShown) card.removeAttribute("aria-label")
    else card.setAttribute("aria-label", card.dataset.markerLabel)
  }

  // Place the column in the page margin right of the document card, then
  // align each card with its highlight, pushing later cards down so they
  // never overlap.
  position() {
    if (!this.marks || this.element.hidden) return
    const layoutRect = this.layout.getBoundingClientRect()
    const cardRight = (this.layout.closest(".plan-document") || this.layout).getBoundingClientRect().right
    const room = document.documentElement.clientWidth - cardRight - GAP - EDGE
    const fits = room >= WIDTH
    const cardsShown = this.mode === "cards" && room >= CARD_MIN_WIDTH
    this.element.toggleAttribute("data-fits", fits)
    this.showCards(cardsShown, Math.min(room, CARD_MAX_WIDTH))
    // A window that was expanded over its card returns to normal width.
    if (!cardsShown && this.activePopover?.classList.contains("thread-popover--card")) placeOnMarginCard(this.activePopover)
    if (!fits) return
    this.element.style.left = `${cardRight + GAP - layoutRect.left}px`

    if (cardsShown && this.measureCards) this.markTruncated()
    const originTop = this.element.getBoundingClientRect().top
    const open = !!this.activePopover?.matches(":popover-open") && !this.activePopover.dataset.positioned
    const expanded = open && cardsShown
    const placed = []
    for (const [id, mark] of this.marks) {
      const card = this.cards.get(id)
      const rect = mark.getClientRects()[0]
      if (!card || !rect) continue
      // A scrolled-out slide anchor must not leave its marker beside prose
      // above or below the deck. getClientRects still includes clipped text.
      const slide = mark.closest(".deck-slide")
      const bounds = slide?.getBoundingClientRect()
      card.hidden = !!bounds && (rect.bottom <= bounds.top || rect.top >= bounds.bottom)
      if (card.hidden) continue
      let top = rect.top - originTop + (cardsShown ? 0 : (rect.height - WIDTH) / 2)
      const active = id === this.activeId
      let height = card.offsetHeight
      if (active && expanded) {
        // Reserve the entire lifted window, including the space above its
        // passage. The card underneath it moves with the expanded window.
        top = marginCardWindowTop(this.activePopover, rect.top) - originTop
        height = Math.max(height, this.activePopover.offsetHeight)
      }
      placed.push({ card, top, height, active, anchorTop: rect.top })
    }
    placed.sort((a, b) => a.anchorTop - b.anchorTop)
    const gap = cardsShown ? STACK_GAP * 2 : STACK_GAP
    this.stack(placed, 0, 0, gap)

    // Earlier cards make room above the active window. If there is no room
    // above the column, put those cards below the window so they remain
    // reachable instead of being covered by the top-layer popover.
    const active = placed.findIndex(item => item.active)
    if (cardsShown && active >= 0) {
      placed[active].y = placed[active].top
      for (let index = active - 1; index >= 0; index--) {
        placed[index].y = Math.min(placed[index].y, placed[index + 1].y - gap - placed[index].height)
      }
      let floor = placed[active].y + placed[active].height + gap
      for (const item of placed.slice(0, active).filter(item => item.y < 0)) {
        item.y = Math.max(item.top, floor)
        floor = item.y + item.height + gap
      }
      this.stack(placed, active + 1, floor, gap)
    }

    for (const { card, y } of placed) card.style.top = `${y}px`
    // Also moves a window onto a card that appeared after it opened, for
    // example when a section badge opens the section around its passage.
    if (!open || !cardsShown) return
    placeOnMarginCard(this.activePopover)
  }

  stack(placed, from, floor, gap) {
    for (let index = from; index < placed.length; index++) {
      const item = placed[index]
      item.y = Math.max(item.top, floor)
      floor = item.y + item.height + gap
    }
  }

  // Switch between markers and cards.
  showCards(shown, width) {
    if (shown) this.element.style.setProperty("--comment-card-width", `${width}px`)
    if (shown && width !== this.cardWidth) this.measureCards = true
    this.cardWidth = shown ? width : null
    if (shown !== this.cardsShown) {
      this.cardsShown = shown
      this.element.classList.toggle("comment-margin--cards", shown)
      this.cards.forEach(card => this.labelCard(card))
    }
    this.report(shown)
  }

  // Tell the Markers / Cards switch whether there is anything to switch,
  // and whether Cards is falling back to markers.
  report(shown) {
    const detail = { cards: shown, fallback: this.mode === "cards" && !shown,
      count: this.element.hasAttribute("data-fits") ? this.cards.size : 0 }
    const state = JSON.stringify(detail)
    if (state === this.reportedState) return
    this.reportedState = state
    document.dispatchEvent(new CustomEvent("coplan:comment-margin-layout", { detail }))
  }

  // A long first comment is clamped to a few lines; show "more" when it is.
  markTruncated() {
    this.measureCards = false
    const truncated = [...this.cards.values()].map(card => {
      const body = card.querySelector(".comment-margin__body")
      return !!body && body.scrollHeight > body.clientHeight + 1
    })
    ;[...this.cards.values()].forEach((card, index) => card.classList.toggle("is-truncated", truncated[index]))
  }

  // Hovering a card or any fragment of its highlight lights up both.
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
    this.highlights(id).forEach(mark => mark.classList.toggle("is-margin-hover", on))
  }

  highlights(id) {
    return this.content.querySelectorAll(`mark.anchor-highlight[data-thread-id="${id}"]`)
  }

  // Opening or closing a section in the document shows or hides the
  // markers or cards inside it, and its badge.
  toggled(event) {
    const target = event.target
    if (target.tagName === "DETAILS" && this.content.contains(target)) this.scheduleRefresh()
  }

  // Keep the card for the open discussion selected and its text emphasised,
  // however it was opened (card, highlight, j/k, a section badge, or a deep
  // link). This runs before the window opens, so the window lands on the
  // card's final place.
  popoverToggled(event) {
    const popover = event.target
    if (!popover.classList?.contains("thread-popover")) return
    const id = popover.id.replace(/_popover$/, "")
    if (event.newState === "open") this.activate(id, popover)
    else if (id === this.activeId) this.activate(null, null)
  }

  activate(id, popover) {
    if (this.activePopover) this.resizeObserver.unobserve(this.activePopover)
    this.markActive(this.activeId, false)
    this.activeId = id
    this.activePopover = popover
    this.markActive(id, true)
    if (popover) {
      this.resizeObserver.observe(popover)
      this.position()
    } else {
      // Wait for the click that closed the window to land before cards move
      // out from under the pointer.
      cancelAnimationFrame(this.positionFrame)
      this.positionFrame = requestAnimationFrame(() => this.position())
    }
  }

  markActive(id, on) {
    if (!id) return
    const card = this.cards.get(id)
    card?.classList.toggle("is-active", on)
    card?.setAttribute("aria-expanded", String(on))
    this.highlights(id).forEach(mark => mark.classList.toggle("is-margin-active", on))
  }
}
