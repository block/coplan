import { Controller } from "@hotwired/stimulus"
import { openExpander, attachExpandAffordance, nearestHeading, ICONS } from "coplan/expander"
import { createPanZoom } from "coplan/pan_zoom"

let diagramId = 0
let mermaidPromise
let configuredTheme

// How far a diagram may be shrunk to fit the document column before
// legibility loses the argument. Past this, the diagram keeps its real size
// and its frame scrolls sideways instead — a label you can't read is worse
// than a scrollbar.
const MIN_INLINE_SCALE = 0.8

// The same bargain in the expanded surface, where there's somewhere to pan
// to: a wide diagram "fitted" to a phone would land at 15%, so fit stops at
// roughly 9px labels and lets you drag the rest into view.
const MIN_EXPANDED_SCALE = 0.55

export default class extends Controller {
  connect() {
    this.renderGeneration ||= 0
    this.boundThemeChange = () => this.renderDiagrams()
    this.colorSchemeQuery = window.matchMedia("(prefers-color-scheme: dark)")
    window.addEventListener("coplan:theme-changed", this.boundThemeChange)
    this.colorSchemeQuery.addEventListener("change", this.boundThemeChange)
    this.sizeObserver = new ResizeObserver(entries => {
      entries.forEach(entry => this.sizeDiagram(entry.target.closest(".mermaid-diagram")))
    })
    this.renderDiagrams()
  }

  disconnect() {
    this.renderGeneration += 1
    window.removeEventListener("coplan:theme-changed", this.boundThemeChange)
    this.colorSchemeQuery.removeEventListener("change", this.boundThemeChange)
    this.sizeObserver?.disconnect()
    this.closeExpanded()
  }

  async renderDiagrams() {
    const sources = [
      ...Array.from(this.element.querySelectorAll('pre[lang="mermaid"] > code'), block => ({
        container: block.parentElement,
        source: block.textContent
      })),
      ...Array.from(this.element.querySelectorAll(".mermaid-diagram[data-mermaid-source]"), diagram => ({
        container: diagram,
        source: diagram.dataset.mermaidSource
      }))
    ]
    if (sources.length === 0) return

    const generation = ++this.renderGeneration

    try {
      const mermaid = await loadMermaid()
      // Mermaid measures label text in the DOM to size its node boxes. Lexend
      // arrives as a swapped webfont, so measuring before it lands sizes every
      // box for the fallback face and the real labels then overflow them.
      await document.fonts?.ready
      if (!this.element.isConnected || generation !== this.renderGeneration) return

      for (const { container, source } of sources) {
        // Sequential renders, so re-configuring per diagram is safe (and
        // a no-op when the theme hasn't changed).
        const theme = configureMermaid(mermaid, diagramDark(container))
        await this.renderDiagram(mermaid, container, source, theme, generation)
      }
    } catch {
      if (this.element.isConnected && generation === this.renderGeneration) {
        sources.forEach(({ container }) => this.showError(container))
      }
    } finally {
      if (this.element.isConnected && generation === this.renderGeneration) {
        this.element.dispatchEvent(new CustomEvent("coplan:mermaid-settled", { bubbles: true }))
      }
    }
  }

  async renderDiagram(mermaid, sourceContainer, source, theme, generation) {
    const id = `coplan-mermaid-${++diagramId}`

    try {
      const { svg, bindFunctions } = await mermaid.render(id, source)
      if (!this.element.isConnected || generation !== this.renderGeneration) return

      const diagram = document.createElement("div")
      diagram.className = "mermaid-diagram"
      diagram.setAttribute("role", "img")
      diagram.setAttribute("aria-label", "Mermaid diagram")
      diagram.dataset.mermaidSource = source
      diagram.dataset.mermaidTheme = theme

      // The SVG lives in its own scroll box so the expand affordance stays
      // pinned to the frame's corner instead of scrolling away with a wide
      // diagram.
      const canvas = document.createElement("div")
      canvas.className = "mermaid-diagram__canvas"
      canvas.innerHTML = svg
      diagram.append(canvas)

      this.makeExpandable(diagram)
      sourceContainer.replaceWith(diagram)
      bindFunctions?.(canvas)
      this.sizeDiagram(diagram)
      this.sizeObserver?.observe(canvas)
    } catch {
      document.getElementById(id)?.remove()
      document.getElementById(`d${id}`)?.remove()
      if (this.element.isConnected && generation === this.renderGeneration) {
        this.showError(sourceContainer)
      }
    }
  }

  // Decides between fitting the diagram to the column and letting it keep
  // its real size behind a horizontal scroll.
  sizeDiagram(diagram) {
    const canvas = diagram?.querySelector(".mermaid-diagram__canvas")
    const svg = canvas?.querySelector("svg")
    if (!svg) return

    const { width, height } = naturalSize(svg)
    const available = canvas.clientWidth
    if (!width || !available) return

    const scrolling = available / width < MIN_INLINE_SCALE
    diagram.classList.toggle("mermaid-diagram--scrolling", scrolling)
    const nextWidth = scrolling ? `${Math.round(width)}px` : ""
    const nextHeight = scrolling ? `${Math.round(height)}px` : ""
    // Only write when the value changes: the observer watches this element,
    // and an unconditional write would keep re-triggering itself.
    if (svg.style.width !== nextWidth) svg.style.width = nextWidth
    if (svg.style.height !== nextHeight) svg.style.height = nextHeight
  }

  makeExpandable(diagram) {
    attachExpandAffordance(diagram, {
      label: "Expand diagram",
      hint: "Expand diagram",
      className: "mermaid-diagram__expand",
      onExpand: () => this.openExpanded(diagram)
    })

    diagram.addEventListener("click", event => {
      // Let clicks on interactive nodes inside the diagram behave normally.
      // Comment marks open their thread popover — expanding here would
      // force-hide it (showModal closes every open popover).
      if (event.target.closest("a, mark.anchor-highlight")) return
      this.openExpanded(diagram)
    })
  }

  openExpanded(diagram) {
    const svg = diagram.querySelector("svg")
    if (!svg || this.expanded) return

    const { width, height } = naturalSize(svg)
    const expander = openExpander({
      title: nearestHeading(diagram) || "Diagram",
      label: "Expanded Mermaid diagram",
      variant: "diagram",
      status: true,
      onClose: () => {
        this.panZoom?.destroy()
        this.panZoom = null
        this.expanded = null
      }
    })
    this.expanded = expander

    const viewport = document.createElement("div")
    viewport.className = "expander__canvas"
    viewport.tabIndex = 0
    const content = svg.cloneNode(true)
    content.removeAttribute("width")
    content.removeAttribute("height")
    viewport.append(content)
    expander.body.append(viewport)

    let readout
    this.panZoom = createPanZoom(viewport, content, {
      width,
      height,
      minFit: MIN_EXPANDED_SCALE,
      onChange: scale => { if (readout) readout.textContent = `${Math.round(scale * 100)}%` }
    })

    // The canvas owns the pan/zoom keys, so every toolbar button hands focus
    // straight back to it — otherwise one click on Zoom in leaves +/-/0/1
    // firing against a button that ignores them.
    const tool = spec => expander.addTool({
      ...spec,
      onClick: () => { spec.onClick(); viewport.focus({ preventScroll: true }) }
    })

    tool({ label: "Zoom out", hint: "Zoom out (−)", icon: ICONS.zoomOut, onClick: () => this.panZoom.zoomOut() })
    readout = expander.addToolReadout(`${Math.round(this.panZoom.scale * 100)}%`)
    tool({ label: "Zoom in", hint: "Zoom in (+)", icon: ICONS.zoomIn, onClick: () => this.panZoom.zoomIn() })
    tool({ label: "Fit to screen", hint: "Fit to screen (0)", icon: ICONS.fit, onClick: () => this.panZoom.fit() })
    tool({ label: "Actual size", hint: "Actual size (1)", icon: ICONS.actual, onClick: () => this.panZoom.actualSize() })

    const hint = document.createElement("span")
    hint.className = "expander__hint"
    // On a touch screen the gestures are the whole interface — and the
    // keyboard shortcuts are not available — so say the touch ones instead.
    hint.textContent = window.matchMedia("(hover: none)").matches
      ? "Drag to pan · pinch to zoom · double-tap to fit"
      : "Drag to pan · scroll or pinch to zoom · double-click to fit · 0 fit · 1 actual size"
    expander.setStatus(hint)

    viewport.focus({ preventScroll: true })
  }

  closeExpanded() {
    this.expanded?.close()
  }

  showError(sourceContainer) {
    if (!sourceContainer.matches('pre[lang="mermaid"]')) return

    sourceContainer.classList.add("mermaid-diagram--error")
    sourceContainer.removeAttribute("lang")

    const message = document.createElement("span")
    message.className = "mermaid-diagram__error-message"
    message.textContent = "Diagram could not be rendered."
    sourceContainer.prepend(message)
  }
}

function loadMermaid() {
  if (mermaidPromise) return mermaidPromise

  mermaidPromise = import("mermaid").then(({ default: mermaid }) => mermaid)
  return mermaidPromise
}

// A mermaid SVG carries its laid-out size in the viewBox; the width/height
// attributes are the responsive "100%" mermaid applies on top.
function naturalSize(svg) {
  const box = svg.viewBox?.baseVal
  if (box?.width) return { width: box.width, height: box.height }

  const rect = svg.getBoundingClientRect()
  return { width: rect.width, height: rect.height }
}

// A deck is a fixed artifact — its diagrams follow the deck theme, not
// the reader's app scheme, so a dark-mode reader sees the same slides as
// a light-mode one. Outside a deck, diagrams follow the app. The theme
// list is small enough to name here; when the theme picker lands, the
// deck can carry scheme metadata instead.
function diagramDark(container) {
  const deck = container.closest(".deck")
  if (deck) return deck.dataset.deckTheme === "graphite"

  const explicitTheme = document.documentElement.dataset.theme
  return explicitTheme === "dark" ||
    (!explicitTheme && window.matchMedia("(prefers-color-scheme: dark)").matches)
}

function configureMermaid(mermaid, dark) {
  const theme = dark ? "dark" : "light"
  if (theme === configuredTheme) return theme

  const fontFamily = appFontStack()
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    suppressErrorRendering: true,
    theme: dark ? "base" : "default",
    // Mermaid's 14px default reads small next to 16px body copy, and it's
    // the label size that survives (or doesn't) being scaled to fit.
    fontFamily,
    themeVariables: { fontSize: "16px", fontFamily, ...(dark && darkThemeVariables()) },
    themeCSS: THEME_CSS,
    flowchart: { padding: 14, nodeSpacing: 55, rankSpacing: 60, useMaxWidth: true },
    sequence: { actorFontSize: 15, messageFontSize: 15, noteFontSize: 14 },
    gantt: { fontSize: 14 }
  })
  configuredTheme = theme
  return theme
}

// Thin hairlines are the other half of "hard to read" — at a reduced scale
// a 1px edge disappears well before its label does.
const THEME_CSS = `
  .flowchart-link, .relationshipLine, .messageLine0, .messageLine1 { stroke-width: 1.75px; }
  .edgeLabel { font-size: 14px; }
  .cluster rect { stroke-width: 1.25px; }
`

function appFontStack() {
  const declared = getComputedStyle(document.documentElement).getPropertyValue("--font-sans").trim()
  return declared || "system-ui, sans-serif"
}

function darkThemeVariables() {
  return {
    darkMode: true,
    background: "#0f172a",
    primaryColor: "#1e3a5f",
    primaryBorderColor: "#60a5fa",
    primaryTextColor: "#eff6ff",
    secondaryColor: "#3b255f",
    secondaryBorderColor: "#a78bfa",
    secondaryTextColor: "#f5f3ff",
    tertiaryColor: "#123f3a",
    tertiaryBorderColor: "#34d399",
    tertiaryTextColor: "#ecfdf5",
    lineColor: "#93c5fd",
    textColor: "#e5eefc",
    mainBkg: "#1e3a5f",
    nodeBorder: "#60a5fa",
    clusterBkg: "#172554",
    clusterBorder: "#818cf8",
    edgeLabelBackground: "#152033",
    actorBkg: "#312e81",
    actorBorder: "#a5b4fc",
    actorTextColor: "#eef2ff",
    actorLineColor: "#64748b",
    signalColor: "#7dd3fc",
    signalTextColor: "#e0f2fe",
    labelBoxBkgColor: "#123f3a",
    labelBoxBorderColor: "#34d399",
    labelTextColor: "#ecfdf5",
    activationBkgColor: "#164e63",
    activationBorderColor: "#22d3ee",
    noteBkgColor: "#713f12",
    noteBorderColor: "#fbbf24",
    noteTextColor: "#fef3c7",
    labelColor: "#eff6ff",
    altBackground: "#3b255f"
  }
}
