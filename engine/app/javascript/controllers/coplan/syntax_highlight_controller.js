import { Controller } from "@hotwired/stimulus"

// Syntax-highlights fenced code blocks (`<pre lang="ruby"><code>`) with
// highlight.js. The core library and each language grammar are loaded from
// the CDN on demand — a page with no code blocks loads nothing, and a page
// with only Ruby loads only the Ruby grammar. Unknown languages are left as
// plain text.
//
// Highlighting rewrites the code element's innerHTML (token <span>s) but
// preserves its textContent exactly, so comment-anchor matching still works.
// Any anchor <mark>s already inside a block are destroyed by the rewrite,
// so a bubbling `coplan:highlight-settled` event is dispatched when done —
// the text-selection controller listens and re-applies highlights, the same
// contract the Mermaid controller uses.

import { loadHljs, loadLanguage } from "coplan/syntax_highlight"

export default class extends Controller {
  connect() {
    this.highlightBlocks()
  }

  async highlightBlocks() {
    const blocks = Array.from(
      this.element.querySelectorAll('pre[lang]:not([lang="mermaid"]) > code:not(.hljs)')
    )

    try {
      if (blocks.length > 0) {
        const hljs = await loadHljs()

        // Phase 1: resolve all grammars concurrently without touching the
        // DOM. Rewriting blocks one-by-one as grammars arrive would destroy
        // comment anchor marks and leave them missing until the slowest
        // grammar settled.
        const jobs = await Promise.all(blocks.map(async code => {
          const lang = code.parentElement.getAttribute("lang").toLowerCase()
          return { code, name: await loadLanguage(hljs, lang) }
        }))

        // Phase 2: rewrite every block in one synchronous pass, then
        // dispatch the settled event. highlightAnchors runs synchronously
        // from that event, so no frame paints without the anchor marks.
        for (const { code, name } of jobs) {
          if (!name || !this.element.contains(code)) continue

          // hljs.highlight (not highlightElement): the input is the block's
          // plain text, the output is escaped token HTML with identical
          // textContent, and no console noise about pre-existing markup.
          const { value } = hljs.highlight(code.textContent, { language: name })
          code.innerHTML = value
          code.classList.add("hljs")
        }
      }
    } catch {
      // CDN unreachable — code blocks stay as readable plain text.
    } finally {
      // Always dispatched, even with zero code blocks: live updates replace
      // the whole .markdown-rendered wrapper, and this reconnect event is
      // what tells the text-selection controller to re-anchor comment marks
      // in the new content.
      if (this.element.isConnected) {
        this.element.dispatchEvent(new CustomEvent("coplan:highlight-settled", { bubbles: true }))
      }
    }
  }
}
