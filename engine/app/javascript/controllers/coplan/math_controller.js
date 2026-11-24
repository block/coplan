import { Controller } from "@hotwired/stimulus"

// Typesets one math element from rendered Markdown with KaTeX. The renderer
// attaches this controller to each element comrak emits for math:
// `<span data-math-style="inline|display">` for `$…$`, `$$…$$` and
// `` $`…`$ ``, `<code data-math-style>` in some inline forms, and
// `<pre lang="math" data-math-style="display">` for ```` ```math ```` fences.
// A page without math never connects it, so KaTeX and its stylesheet load
// only when a page needs them.
//
// The element keeps its TeX source until KaTeX and its stylesheet have both
// arrived; unstyled KaTeX output would show every formula twice. If either
// fails to load, or an expression cannot be typeset, the reader sees the
// source. Comment anchoring treats math elements as atomic, so replacing
// their contents never disturbs highlights.

// Keep in step with the "katex" pin in config/importmap.rb.
const KATEX_STYLESHEET = "https://cdn.jsdelivr.net/npm/katex@0.19.1/dist/katex.min.css"
const KATEX_STYLESHEET_INTEGRITY = "sha384-WwGtaC6ywCHxA5cstpj/3+xIZvTez8dq2IcBQaXRkenHZ7FVVq1ZROtURwfbtTlG"

let katexPromise

export default class extends Controller {
  connect() {
    // A Turbo snapshot restores already-typeset math; keep rendering from
    // the original source rather than KaTeX's output.
    this.element.dataset.mathSource ??= this.element.matches("pre") ?
      (this.element.querySelector("code") || this.element).textContent.replace(/\n$/, "") :
      this.element.textContent
    this.render()
  }

  async render() {
    const source = this.element.dataset.mathSource
    let katex
    try {
      katex = await loadKatex()
    } catch {
      return // CDN unreachable: the source stays readable.
    }
    if (!this.element.isConnected || this.element.dataset.mathSource !== source) return

    try {
      katex.render(source, this.element, {
        displayMode: this.element.dataset.mathStyle === "display",
        throwOnError: false,
        trust: false,
        strict: "warn"
      })
      this.element.classList.add("is-math-rendered")
      this.element.classList.toggle("is-math-error", !!this.element.querySelector(".katex-error"))
    } catch {
      this.element.textContent = source
      this.element.classList.remove("is-math-rendered")
      this.element.classList.add("is-math-error")
    }
  }
}

function loadKatex() {
  // Don't cache a rejection: a transient CDN failure should not disable
  // math for the rest of the Turbo session.
  katexPromise ||= Promise.all([import("katex"), loadStylesheet()])
    .then(([module]) => module.default)
    .catch(error => {
      katexPromise = null
      throw error
    })
  return katexPromise
}

function loadStylesheet() {
  let link = document.querySelector(`link[href="${KATEX_STYLESHEET}"]`)
  if (link?.sheet) return Promise.resolve()

  if (!link) {
    link = document.createElement("link")
    link.rel = "stylesheet"
    link.href = KATEX_STYLESHEET
    link.integrity = KATEX_STYLESHEET_INTEGRITY
    link.crossOrigin = "anonymous"
    // Left untracked: Turbo drops only data-turbo-track="dynamic"
    // stylesheets on later visits, so this one stays loaded.
    document.head.append(link)
  }
  return new Promise((resolve, reject) => {
    link.addEventListener("load", () => resolve(), { once: true })
    link.addEventListener("error", () => { link.remove(); reject(new Error("KaTeX stylesheet unavailable")) }, { once: true })
  })
}
