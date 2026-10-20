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
