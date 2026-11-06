// Whether the plan page margin shows discussion markers or cards. The choice
// is remembered per user in this browser.
export const MARGIN_MODES = ["markers", "cards"]

function preferenceKey() {
  const user = document.querySelector("meta[name='coplan-current-user-id']")?.content || "guest"
  return `coplan:comment-margin:${user}`
}

export function commentMarginMode() {
  try {
    const mode = localStorage.getItem(preferenceKey())
    return MARGIN_MODES.includes(mode) ? mode : "markers"
  } catch {
    return "markers"
  }
}

export function setCommentMarginMode(mode) {
  if (!MARGIN_MODES.includes(mode)) return
  try { localStorage.setItem(preferenceKey(), mode) } catch {}
  document.dispatchEvent(new CustomEvent("coplan:comment-margin-mode", { detail: { mode } }))
}
