// One catalog, shared with the server-rendered help. Component controllers
// register commands for their lifetime; only the Stimulus dispatcher listens
// globally. Focused widgets use commandFor without registering page shortcuts.
const registrations = new Set()
let catalogElement, catalog

export function shortcutCatalog() {
  const element = document.getElementById("coplan-shortcut-catalog")
  if (element !== catalogElement) {
    catalogElement = element
    catalog = element ? JSON.parse(element.textContent) : {}
  }
  return catalog || {}
}

export function commandFor(scope, event) {
  if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
  return shortcutCatalog()[scope]?.bindings.find(binding =>
    !binding.native && binding.keys.some(key => matches(key, event)))?.id
}

function matches(chord, event) {
  const parts = chord.split("+")
  const key = parts.pop()
  const mod = parts.includes("Mod")
  if (mod ? !(event.metaKey || event.ctrlKey) : (event.metaKey || event.ctrlKey)) return false
  if (event.altKey !== parts.includes("Alt")) return false
  // Printable symbols already encode Shift in event.key ("?", "{", etc.).
  if ((key.length > 1 || parts.includes("Shift")) && event.shiftKey !== parts.includes("Shift")) return false
  return event.key === key
}

export function typing(event) {
  return event.target?.isContentEditable || !!event.target?.closest?.("input, textarea, select, [role='textbox']")
}

export function registerShortcuts(controller, scope, handler, options = {}) {
  if (!shortcutCatalog()[scope] || shortcutCatalog()[scope].local) {
    throw new Error(`Unknown or widget-local shortcut scope: ${scope}`)
  }
  const registration = { controller, scope, handler, ...options }
  registrations.add(registration)
  return () => registrations.delete(registration)
}

export function pageShortcutsAllowed(scope) {
  if (document.querySelector("dialog[open]")) return false
  const overlays = [...document.querySelectorAll(":popover-open")]
  const allowed = shortcutCatalog()[scope]?.overlays || []
  return overlays.every(element => allowed.some(selector => element.matches(selector)))
}

export function dispatchShortcut(event, { capture = false } = {}) {
  if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
  const active = [...registrations].filter(entry => entry.controller.element.isConnected)
  // Help can open above any surface, but never steals literal text entry.
  const global = active.find(entry => shortcutCatalog()[entry.scope].global && commandFor(entry.scope, event))
  if (capture && !typing(event) && global) {
    global.handler(event)
    event.stopPropagation()
    return
  }
  // An exclusive surface (currently presentation mode) owns page shortcuts.
  // Focused dialogs and editable widgets keep their own event handling.
  const exclusive = active.find(entry => entry.exclusive?.())
  if (exclusive) {
    if (capture && !document.querySelector("dialog[open]")) exclusive.handler(event)
    return
  }
  // Ordinary page commands bubble, so focused widgets get first refusal.
  if (capture || typing(event)) return
  for (const entry of active) {
    if (shortcutCatalog()[entry.scope].global) continue
    if (!pageShortcutsAllowed(entry.scope) || !commandFor(entry.scope, event)) continue
    entry.handler(event)
    if (event.defaultPrevented) break
  }
}
