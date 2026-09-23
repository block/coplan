import { Controller } from "@hotwired/stimulus"
import { openExpander, attachExpandAffordance, nearestHeading, ICONS } from "coplan/expander"
import { createPanZoom } from "coplan/pan_zoom"

let diagramId = 0
let mermaidPromise
let configuredTheme

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
    this.boundResize = () => this.element.querySelectorAll(".mermaid-diagram").forEach(diagram => this.sizeDiagram(diagram))
    window.addEventListener("resize", this.boundResize)
    this.renderDiagrams()
  }

  disconnect() {
    this.renderGeneration += 1
    window.removeEventListener("coplan:theme-changed", this.boundThemeChange)
    this.colorSchemeQuery.removeEventListener("change", this.boundThemeChange)
    this.sizeObserver?.disconnect()
    window.removeEventListener("resize", this.boundResize)
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
      diagram.classList.toggle("is-comment-mode", sourceContainer.classList.contains("is-comment-mode"))
      diagram.setAttribute("role", "img")
      diagram.setAttribute("aria-label", "Mermaid diagram")
      diagram.dataset.mermaidSource = source
      diagram.dataset.mermaidTheme = theme
      if (sourceContainer.dataset.sourceTargets) diagram.dataset.sourceTargets = sourceContainer.dataset.sourceTargets

      // The SVG lives in its own scroll box so the expand affordance stays
      // pinned to the frame's corner instead of scrolling away with a wide
      // diagram.
      const canvas = document.createElement("div")
      canvas.className = "mermaid-diagram__canvas"
      canvas.innerHTML = svg
      diagram.append(canvas)

      await this.bindSourceTargets(mermaid, diagram, source)
      if (!this.element.isConnected || generation !== this.renderGeneration) return

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

  // Inline diagrams are complete overviews. Expansion and zoom provide the
  // detail; neither long nor tall diagrams should start cropped.
  sizeDiagram(diagram) {
    const canvas = diagram?.querySelector(".mermaid-diagram__canvas")
    const svg = canvas?.querySelector("svg")
    if (!svg || diagram.closest(".deck")) return
    const { width, height } = naturalSize(svg)
    const padding = getComputedStyle(canvas)
    const available = canvas.clientWidth - parseFloat(padding.paddingLeft) - parseFloat(padding.paddingRight)
    if (!width || !height || available <= 0) return
    const scale = Math.min(1, available / width, Math.max(200, window.innerHeight * 0.65) / height)
    const nextWidth = `${width * scale}px`
    const nextHeight = `${height * scale}px`
    diagram.classList.remove("mermaid-diagram--scrolling")
    if (svg.style.width !== nextWidth) svg.style.width = nextWidth
    if (svg.style.height !== nextHeight) svg.style.height = nextHeight
  }

  makeExpandable(diagram) {
    diagram.tabIndex = 0
    diagram.setAttribute("aria-label", "Diagram. Press C for comment mode, Enter to expand.")
    attachExpandAffordance(diagram, {
      label: "Expand diagram",
      hint: "Expand diagram",
      className: "mermaid-diagram__expand",
      onExpand: () => this.openExpanded(diagram)
    })

    diagram.addEventListener("dblclick", event => {
      // Let clicks on interactive nodes inside the diagram behave normally.
      // Comment marks open their thread popover — expanding here would
      // force-hide it (showModal closes every open popover).
      if (event.target.closest("a, button, .anchor-highlight, [data-source-badge]") || diagram.classList.contains("is-comment-mode")) return
      event.preventDefault()
      window.getSelection()?.removeAllRanges()
      this.openExpanded(diagram)
    })
    this.addCommentMode(diagram, diagram, JSON.parse(diagram.dataset.sourceTargets || "null"))
    diagram.addEventListener("keydown", event => {
      if (event.target === diagram && event.key === "Enter") {
        event.preventDefault()
        this.openExpanded(diagram)
      }
    })
  }

  addCommentMode(surface, controls, map) {
    if (!map?.diagram) return
    const actions = document.createElement("div")
    actions.className = "diagram-comments"
    const toggle = document.createElement("button")
    toggle.type = "button"
    toggle.className = "btn btn--secondary btn--sm diagram-comments__toggle"
    toggle.innerHTML = "<kbd>C</kbd> Comment"
    toggle.setAttribute("aria-pressed", "false")
    toggle.hidden = surface.matches(".mermaid-diagram")
    const hint = document.createElement("span")
    hint.className = "diagram-comments__hint"
    hint.hidden = true
    const targets = () => [
      ...surface.querySelectorAll("svg g.node[data-source-target]"),
      ...surface.querySelectorAll("svg path.flowchart-link[data-source-target]:not(.source-edge-hit)")
    ]
    hint.textContent = targets().length ? "Hover an item to comment · Esc to browse" : "Whole-diagram comments available · Esc to browse"
    const whole = document.createElement("button")
    whole.type = "button"
    whole.className = "btn btn--secondary btn--sm diagram-comments__whole"
    whole.textContent = "Comment on whole diagram"
    whole.dataset.sourceTarget = JSON.stringify(map.diagram)
    whole.dataset.action = "click->coplan--source-comments#commentOnDiagram"
    whole.hidden = true
    actions.append(toggle, hint, whole)
    controls.append(actions)
    const setMode = (active, keyboard = false, moveFocus = true) => {
      if (active && moveFocus) window.getSelection()?.removeAllRanges()
      surface.classList.toggle("is-comment-mode", active)
      surface.classList.toggle("is-whole-diagram-comment", active && targets().length === 0)
      toggle.setAttribute("aria-pressed", String(active))
      hint.hidden = !active
      whole.hidden = !active && !whole.classList.contains("has-source-comments")
      targets().forEach(target => { target.tabIndex = active ? 0 : -1 })
      if (!moveFocus) return
      // Entering a mode must not choose a target. Tab explicitly moves into it.
      if (active && keyboard) (surface.querySelector(".expander__canvas") || surface).focus({ preventScroll: true })
      else if (active) toggle.focus({ preventScroll: true })
      else (surface.querySelector(".expander__canvas") || surface).focus({ preventScroll: true })
    }
    // Rebuilding for a theme change preserves mode without stealing focus
    // from an open comment/reply field or clearing the reader's selection.
    setMode(surface.classList.contains("is-comment-mode"), false, false)
    toggle.addEventListener("click", () => setMode(!surface.classList.contains("is-comment-mode")))
    surface.addEventListener("click", event => {
      if (surface.classList.contains("is-whole-diagram-comment") &&
          event.target.closest(".mermaid-diagram__canvas, .expander__canvas") && !event.target.closest("a, button")) whole.click()
    })
    surface.addEventListener("keydown", event => {
      if (event.ctrlKey || event.metaKey || event.altKey || event.target.closest("input, textarea, select, [contenteditable], .source-comments")) return
      if (event.key.toLowerCase() === "c" || (event.key === "Escape" && surface.classList.contains("is-comment-mode"))) {
        event.preventDefault()
        event.stopPropagation()
        setMode(event.key !== "Escape" && !surface.classList.contains("is-comment-mode"), true)
      }
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
      container: this.element.closest('[data-controller~="coplan--source-comments"]') || document.body,
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
    expander.dialog.dispatchEvent(new CustomEvent("coplan:expander-opened", { bubbles: true }))

    let readout
    this.panZoom = createPanZoom(viewport, content, {
      width,
      height,
      onChange: scale => {
        if (readout) readout.textContent = `${Math.round(scale * 100)}%`
        this.element.dispatchEvent(new CustomEvent("coplan:diagram-moved", { bubbles: true }))
      }
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
    this.addCommentMode(expander.dialog, expander.dialog.querySelector(".expander__status"),
      JSON.parse(diagram.dataset.sourceTargets || "null"))
    // The whole-diagram action is another representation of the same thread.
    expander.dialog.dispatchEvent(new CustomEvent("coplan:expander-opened", { bubbles: true }))

    viewport.focus({ preventScroll: true })
  }

  async bindSourceTargets(mermaid, diagram, source) {
    if (!diagram.dataset.sourceTargets) return
    try {
      const map = JSON.parse(diagram.dataset.sourceTargets)
      const parsed = await mermaid.mermaidAPI.getDiagramFromText(source)
      const vertices = parsed.db.getVertices()
      const edges = parsed.db.getEdges()
      // Validate the complete edge sequence against Mermaid's own parser.
      // A new syntax/version must fail closed, never shift edge ordinals.
      if (edges.length !== map.edges.length || edges.some((edge, i) =>
        edge.start !== map.edges[i].from || edge.end !== map.edges[i].to)) return

      const bind = (element, target) => {
        element.dataset.sourceTarget = JSON.stringify(target)
        element.dataset.action = "click->coplan--source-comments#select keydown->coplan--source-comments#key"
        element.setAttribute("tabindex", "0")
        element.setAttribute("role", "button")
        element.setAttribute("aria-label", `${target.label}. Enter to comment.`)
      }
      const matching = (selector, id) => Array.from(diagram.querySelectorAll(selector))
        .filter(el => el.id === id || el.id.endsWith(`-${id}`))
      Object.entries(map.nodes).forEach(([id, target]) => {
        const vertex = vertices.get(id)
        if (!vertex) return
        const elements = matching("g.node", vertex.domId)
        if (elements.length === 1) {
          const node = elements[0]
          bind(node, target)
          // Mermaid wraps some shapes (stadiums, documents, etc.) in groups.
          // Mark geometry rather than assuming each shape is a direct child.
          node.querySelectorAll("rect, circle, ellipse, polygon, path").forEach(shape => {
            if (!shape.closest(".label, .source-thread-badge")) shape.classList.add("source-node-shape")
          })
        }
      })
      edges.forEach((edge, i) => {
        const elements = matching("path.flowchart-link", edge.id)
        if (elements.length !== 1) return
        const path = elements[0]
        bind(path, map.edges[i])
        const label = Array.from(diagram.querySelectorAll('.edgeLabels .label[data-id]'))
          .find(label => label.dataset.id === edge.id)?.closest('g.edgeLabel')
        if (label && label.textContent.trim()) {
          bind(label, map.edges[i])
          label.classList.add("source-edge-label")
          // The path remains the single keyboard target for this connection.
          label.setAttribute("tabindex", "-1")
        }
        // An invisible sibling receives taps without changing the visible
        // line's stroke or marker. Geometry stays in the SVG's coordinates.
        const hit = path.cloneNode(false)
        hit.removeAttribute("id")
        hit.removeAttribute("style")
        hit.removeAttribute("marker-start")
        hit.removeAttribute("marker-end")
        hit.removeAttribute("tabindex")
        hit.setAttribute("aria-hidden", "true")
        hit.classList.add("source-edge-hit")
        path.after(hit)
      })
      diagram.setAttribute("role", "group")
    } catch {
      // Source commenting is optional; a parser API change must not prevent
      // viewing or expanding the diagram.
    }
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
  // The base theme darkens its derived category palette to black in dark
  // mode. Explicit colors keep mindmap branches visible on our dark canvas.
  const categoryColors = ["#345f87", "#59467e", "#28685f", "#526c91", "#665583", "#36766d"]
  const categories = Object.fromEntries(Array.from({ length: 12 }, (_, index) =>
    [`cScale${index}`, categoryColors[index % categoryColors.length]]))
  return {
    ...categories,
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
    altBackground: "#3b255f",
    gitBranchLabel0: "#eff6ff",
    // Gantt's base defaults assume a white page, including completed tasks.
    sectionBkgColor: "#20344d",
    altSectionBkgColor: "#152033",
    sectionBkgColor2: "#24354b",
    excludeBkgColor: "#334155",
    doneTaskBkgColor: "#334155",
    doneTaskBorderColor: "#64748b",
    gridColor: "#64748b"
  }
}
