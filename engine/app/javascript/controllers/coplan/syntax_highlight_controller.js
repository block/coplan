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

// The /+esm endpoint is required: the raw files in the npm package re-export
// from CommonJS modules, which browsers can't import. jsDelivr's +esm builds
// proper ESM bundles with default exports.
const HLJS_VERSION = "11.11.1"
const CDN_BASE = `https://cdn.jsdelivr.net/npm/highlight.js@${HLJS_VERSION}/lib`

// Fence tags whose highlight.js grammar lives under a different file name.
// Each grammar module registers its own aliases once loaded, but the file
// we import must be the canonical name.
const LANGUAGE_FILES = {
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  ts: "typescript", tsx: "typescript", mts: "typescript", cts: "typescript",
  html: "xml", xhtml: "xml", svg: "xml", plist: "xml",
  sh: "bash", zsh: "bash",
  console: "shell", shellsession: "shell",
  yml: "yaml",
  rb: "ruby", gemspec: "ruby", irb: "ruby",
  py: "python",
  golang: "go",
  "c++": "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp",
  "c#": "csharp", cs: "csharp",
  "f#": "fsharp", fs: "fsharp",
  kt: "kotlin", kts: "kotlin",
  rs: "rust",
  ps: "powershell", ps1: "powershell",
  docker: "dockerfile",
  proto: "protobuf",
  objc: "objectivec", "objective-c": "objectivec",
  md: "markdown", mkdown: "markdown",
  pl: "perl",
  hs: "haskell",
  gql: "graphql",
  tex: "latex",
  text: "plaintext", txt: "plaintext", plain: "plaintext"
}

let hljsPromise
const languagePromises = new Map()

function loadHljs() {
  // Don't cache a rejected import — a transient CDN failure would otherwise
  // disable highlighting for the rest of the Turbo session.
  hljsPromise ||= import(`${CDN_BASE}/core/+esm`)
    .then(module => module.default)
    .catch(error => {
      hljsPromise = null
      throw error
    })
  return hljsPromise
}

// Resolves a fence tag to a registered grammar name, importing the grammar
// module on first use. Returns null when the language isn't recognized.
async function loadLanguage(hljs, lang) {
  const name = LANGUAGE_FILES[lang] || lang
  // Grammar file names are strictly [a-z0-9-]. The fence tag comes from
  // untrusted plan content — anything else must never reach the CDN URL.
  if (!/^[a-z0-9-]{1,42}$/.test(name)) return null
  if (hljs.getLanguage(name)) return name

  if (!languagePromises.has(name)) {
    languagePromises.set(name,
      import(`${CDN_BASE}/languages/${name}/+esm`)
        .then(module => {
          hljs.registerLanguage(name, module.default)
          return name
        })
        .catch(() => {
          // Unknown language or transient failure — don't cache it, so a
          // later page view can retry.
          languagePromises.delete(name)
          return null
        }))
  }
  return languagePromises.get(name)
}

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
