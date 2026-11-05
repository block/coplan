// Preserve the control within the same visible discussion, including table
// copies whose ids are stripped. Never steal focus from a subsequent action.
export function captureReactionFocus() {
  const focused = document.activeElement
  const reactions = focused?.closest(".comment-reactions")
  if (!reactions) return () => {}
  const scope = reactions.closest(".source-comments") || document
  const commentId = reactions.getAttribute("data-coplan--comment-reactions-comment-id-value")
  const kind = focused.matches(".comment-reaction") ? focused.dataset.kind : null
  return () => {
    if (focused.isConnected || document.activeElement !== document.body) return
    const copies = scope.querySelectorAll(`[data-coplan--comment-reactions-comment-id-value="${CSS.escape(commentId)}"]`)
    for (const copy of copies) {
      const chip = kind && copy.querySelector(`.comment-reaction[data-kind="${CSS.escape(kind)}"]`)
      const target = chip || copy.querySelector(".comment-reactions__add")
      if (target?.getClientRects().length) {
        target.focus({ preventScroll: true })
        return
      }
    }
  }
}
