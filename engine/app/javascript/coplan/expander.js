// The shared takeover surface. Two very different things in a plan — a
// Mermaid diagram and a data table — both need the identical outer
// experience: a modal that owns the viewport, one title/toolbar/close
// chrome, disciplined dismissal, and the keyboard to itself while open.
// Only what happens *inside* the body differs (pan-zoom for a diagram, a
// cell cursor for a table), so that part is the caller's business.
//
// Dismissal is deliberately narrow: backdrop or Escape. The Mermaid
// lightbox this replaces closed on any click anywhere, which is precisely
// why it could never support panning — every drag ended in a close.

let current = null

export const ICONS = {
  expand: icon('<path d="M9.5 2.5h4v4M13.5 2.5 9 7M6.5 13.5h-4v-4M2.5 13.5 7 9"/>'),
  close: icon('<path d="M3.5 3.5l9 9M12.5 3.5l-9 9"/>'),
  zoomIn: icon('<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14M7 5v4M5 7h4"/>'),
  zoomOut: icon('<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14M5 7h4"/>'),
  fit: icon('<path d="M2.5 6v-3.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/>'),
  actual: icon('<path d="M2.5 8h11M5 5.5 2.5 8 5 10.5M11 5.5 13.5 8 11 10.5"/>'),
  wrap: icon('<path d="M2 3.5h12M2 8h9a2.5 2.5 0 0 1 0 5H8M9.5 11 8 13l1.5 2M2 12.5h3"/>'),
  unsort: icon('<path d="M2.5 4h11M4.5 8h7M6.5 12h3"/>')
}

// Opens the surface. Returns a handle: fill `body`, hang controls off
// `addTool`, write a one-line readout with `setStatus`.
export function openExpander({ title = "", label = "Expanded view", variant = null, status = false, onClose = null } = {}) {
  current?.close()

  const dialog = document.createElement("dialog")
  dialog.className = [ "expander", variant && `expander--${variant}` ].filter(Boolean).join(" ")
  dialog.setAttribute("aria-label", label)
  // Turbo caches the page on navigation; a cached open dialog would come
  // back as a dead overlay with no controller behind it.
  dialog.dataset.turboTemporary = ""

  const bar = element("header", "expander__bar")
  const heading = element("h2", "expander__title")
  heading.textContent = title
  const tools = element("div", "expander__tools")
  const closeButton = toolButton({ label: "Close", hint: "Close (Esc)", icon: ICONS.close, className: "expander__close" })
  closeButton.addEventListener("click", () => dialog.close())
  bar.append(heading, tools, closeButton)

  const body = element("div", "expander__body")
  dialog.append(bar, body)

  const statusBar = status ? element("footer", "expander__status") : null
  if (statusBar) dialog.append(statusBar)

  dialog.addEventListener("pointerdown", event => {
    // The bar, body and status bar tile the dialog completely, so the
    // dialog itself is only ever the event target for a backdrop press.
    if (event.target === dialog) dialog.close()
  })

  // While a takeover is open it owns the keyboard: the page's hotkey
  // controllers all listen on `document`, so stopping the event here — on
  // the way out, after everything inside the dialog has seen it — keeps
  // `[`/`]`/`j`/Backspace/Ctrl+Space from firing against the document
  // hidden behind the overlay. Escape still closes: that's the UA's
  // default action, which propagation doesn't govern.
  dialog.addEventListener("keydown", event => {
    if (!isTyping(event.target)) event.stopPropagation()
  })

  const handle = {
    dialog,
    body,
    addTool: spec => {
      const button = toolButton(spec)
      if (spec.onClick) button.addEventListener("click", spec.onClick)
      tools.append(button)
      return button
    },
    addToolReadout: text => {
      const readout = element("span", "expander__readout")
      readout.textContent = text
      tools.append(readout)
      return readout
    },
    setStatus: nodes => {
      if (!statusBar) return
      statusBar.replaceChildren(...(Array.isArray(nodes) ? nodes : [ nodes ]))
    },
    setTitle: text => { heading.textContent = text },
    close: () => dialog.close()
  }

  dialog.addEventListener("close", () => {
    document.documentElement.classList.remove("expander-open")
    dialog.remove()
    if (current === handle) current = null
    onClose?.()
  })

  current = handle
  document.documentElement.classList.add("expander-open")
  document.body.append(dialog)
  dialog.showModal()
  return handle
}

// The corner control that opens the surface. Shared so a table and a
// diagram present the same affordance in the same place.
export function attachExpandAffordance(container, { label, hint, onExpand, className }) {
  const button = toolButton({ label, hint: hint || label, icon: ICONS.expand, className })
  // Turbo caches the DOM as it stands, including this button — and on a back
  // navigation the controller reconnects against that snapshot and appends
  // another one. Marking it temporary keeps it out of the cached copy, so
  // there's always exactly one affordance in the corner.
  button.dataset.turboTemporary = ""
  button.addEventListener("click", event => {
    event.preventDefault()
    event.stopPropagation()
    onExpand()
  })
  container.append(button)
  return button
}

export function closeExpander() {
  current?.close()
}

// The heading a block sits under, so an expanded view can say what you're
// looking at instead of just "Table" or "Diagram". Walks backwards through
// preceding siblings, then out of the enclosing section, and stops at the
// rendered-markdown root.
export function nearestHeading(element) {
  let node = element
  while (node && !node.classList?.contains("markdown-rendered")) {
    if (/^H[1-6]$/.test(node.tagName)) return node.textContent.trim()
    node = node.previousElementSibling || node.parentElement
  }
  return null
}

function toolButton({ label, hint, icon: markup, text, className }) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = className || "expander__tool"
  button.setAttribute("aria-label", label)
  if (hint) button.title = hint
  button.innerHTML = markup || ""
  if (text) {
    const span = document.createElement("span")
    span.textContent = text
    button.append(span)
  }
  return button
}

function element(name, className) {
  const node = document.createElement(name)
  node.className = className
  return node
}

function icon(paths) {
  return `<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" ` +
    `stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`
}

function isTyping(target) {
  const tag = target?.tagName
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || target?.isContentEditable
}
