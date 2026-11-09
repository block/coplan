// Popovers live above every stacking context. Reserve the pinned controls
// explicitly so a tall discussion cannot intercept their mouse clicks.
export function commentWindowTop(element) {
  let top = 12
  if (!window.matchMedia("(max-width: 640px)").matches) {
    const nav = document.querySelector(".site-nav")
    if (nav?.getClientRects().length) top = Math.max(top, nav.getBoundingClientRect().bottom + 8)
    for (const toolbar of document.querySelectorAll(".document-editor__toolbar")) {
      if (!toolbar.getClientRects().length || getComputedStyle(toolbar).visibility === "hidden") continue
      const rect = toolbar.getBoundingClientRect()
      if (rect.top <= top + 1 && rect.bottom > 0) top = Math.max(top, rect.bottom + 8)
    }
  }
  element.style.setProperty("--comment-window-top", `${top}px`)
  return top
}

// In Cards mode a discussion window opens over its margin card, at the
// card's width, so the card appears to expand in place. Returns false when
// the thread has no visible card, so the caller places the window itself.
export function placeOnMarginCard(popover) {
  const id = popover.id.replace(/_popover$/, "")
  const card = document.querySelector(`.comment-margin--cards[data-fits] .comment-margin__card[data-thread-id="${id}"]:not([hidden])`)
  const wasOnCard = popover.classList.contains("thread-popover--card")
  popover.classList.toggle("thread-popover--card", !!card)
  if (!card) {
    // Cards just switched off: return to the normal width without leaving
    // the window hanging off the right edge until it is placed again.
    if (wasOnCard) {
      popover.style.width = ""
      const left = Math.min(popover.getBoundingClientRect().left, window.innerWidth - popover.offsetWidth - 16)
      popover.style.left = `${Math.max(16, left)}px`
    }
    return false
  }
  popover.classList.remove("thread-popover--sheet")
  const rect = card.getBoundingClientRect()
  popover.style.width = `${rect.width}px`
  popover.style.left = `${rect.left}px`
  popover.style.top = `${marginCardWindowTop(popover, rect.top)}px`
  return true
}

// A card window starts level with its card, below the pinned controls. When
// it runs past the bottom of the window and the page cannot scroll far
// enough to show it (a short plan, or a card near the end), it moves up
// just enough to keep its reply box and actions on screen, but never above
// the pinned controls.
export function marginCardWindowTop(popover, cardTop) {
  const minimumTop = commentWindowTop(popover)
  const top = Math.max(minimumTop, cardTop)
  const viewport = window.visualViewport?.height || window.innerHeight
  const overflow = top + popover.offsetHeight - (viewport - 12)
  const scrollable = Math.max(0, document.documentElement.scrollHeight - viewport - window.scrollY)
  return Math.max(minimumTop, top - Math.max(0, overflow - scrollable))
}
