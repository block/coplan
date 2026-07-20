import { Controller } from "@hotwired/stimulus"

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
    this.renderDiagrams()
  }

  disconnect() {
    this.renderGeneration += 1
    window.removeEventListener("coplan:theme-changed", this.boundThemeChange)
    this.colorSchemeQuery.removeEventListener("change", this.boundThemeChange)
    this.lightbox?.close()
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
      if (!this.element.isConnected || generation !== this.renderGeneration) return

      const theme = configureMermaid(mermaid)
      for (const { container, source } of sources) {
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
      diagram.innerHTML = svg
      this.makeExpandable(diagram)
      sourceContainer.replaceWith(diagram)
      bindFunctions?.(diagram)
    } catch {
      document.getElementById(id)?.remove()
      document.getElementById(`d${id}`)?.remove()
      if (this.element.isConnected && generation === this.renderGeneration) {
        this.showError(sourceContainer)
      }
    }
  }

  makeExpandable(diagram) {
    const expand = document.createElement("button")
    expand.type = "button"
    expand.className = "mermaid-diagram__expand"
    expand.setAttribute("aria-label", "Expand diagram")
    expand.title = "Expand diagram"
    expand.innerHTML = EXPAND_ICON
    diagram.append(expand)

    diagram.addEventListener("click", event => {
      // Let clicks on interactive nodes inside the diagram behave normally.
      // Comment marks open their thread popover — expanding here would
      // force-hide it (showModal closes every open popover).
      if (event.target.closest("a, mark.anchor-highlight")) return
      this.openLightbox(diagram)
    })
  }

  openLightbox(diagram) {
    const svg = diagram.querySelector("svg")
    if (!svg || this.lightbox) return

    const lightbox = document.createElement("dialog")
    lightbox.className = "mermaid-lightbox"
    lightbox.setAttribute("aria-label", "Expanded Mermaid diagram")
    lightbox.dataset.turboTemporary = ""

    const close = document.createElement("button")
    close.type = "button"
    close.className = "mermaid-lightbox__close"
    close.setAttribute("aria-label", "Close expanded diagram")
    close.title = "Close"
    close.innerHTML = CLOSE_ICON

    const content = svg.cloneNode(true)
    content.removeAttribute("width")
    content.removeAttribute("height")
    content.style.maxWidth = "none"
    content.style.width = "100%"
    content.style.height = "100%"

    lightbox.append(close, content)
    lightbox.addEventListener("click", () => lightbox.close())
    lightbox.addEventListener("close", () => {
      lightbox.remove()
      if (this.lightbox === lightbox) this.lightbox = null
    })

    this.lightbox = lightbox
    document.body.append(lightbox)
    lightbox.showModal()
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

const EXPAND_ICON = `
  <svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M9.5 2.5h4v4M13.5 2.5 9 7M6.5 13.5h-4v-4M2.5 13.5 7 9"/>
  </svg>
`

const CLOSE_ICON = `
  <svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
    <path d="M3.5 3.5l9 9M12.5 3.5l-9 9"/>
  </svg>
`

function loadMermaid() {
  if (mermaidPromise) return mermaidPromise

  mermaidPromise = import("mermaid").then(({ default: mermaid }) => mermaid)
  return mermaidPromise
}

function configureMermaid(mermaid) {
  const explicitTheme = document.documentElement.dataset.theme
  const dark = explicitTheme === "dark" ||
    (!explicitTheme && window.matchMedia("(prefers-color-scheme: dark)").matches)
  const theme = dark ? "dark" : "light"
  if (theme === configuredTheme) return theme

  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    suppressErrorRendering: true,
    theme: dark ? "base" : "default",
    ...(dark && { themeVariables: darkThemeVariables() })
  })
  configuredTheme = theme
  return theme
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
