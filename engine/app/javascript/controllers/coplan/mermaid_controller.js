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

    let mermaid
    try {
      mermaid = await loadMermaid()
    } catch {
      sources.forEach(({ container }) => this.showError(container))
      return
    }

    const theme = configureMermaid(mermaid)
    const generation = ++this.renderGeneration

    for (const { container, source } of sources) {
      await this.renderDiagram(mermaid, container, source, theme, generation)
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
      sourceContainer.replaceWith(diagram)
      bindFunctions?.(diagram)
    } catch {
      document.getElementById(id)?.remove()
      document.getElementById(`d${id}`)?.remove()
      this.showError(sourceContainer)
    }
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

function configureMermaid(mermaid) {
  const explicitTheme = document.documentElement.dataset.theme
  const dark = explicitTheme === "dark" ||
    (!explicitTheme && window.matchMedia("(prefers-color-scheme: dark)").matches)
  const theme = dark ? "dark" : "default"
  if (theme === configuredTheme) return theme

  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    suppressErrorRendering: true,
    theme
  })
  configuredTheme = theme
  return theme
}
