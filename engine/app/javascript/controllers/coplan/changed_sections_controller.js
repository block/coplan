import { Controller } from "@hotwired/stimulus"

// One-time "changed since you last looked" highlights. The server passes
// the slug keys of sections whose content changed since this viewer's
// last visit (Plans::ChangedSections); we tint those sections — heading
// through to the next heading — and drop a small note above the content.
// The server advanced last_seen_at on this same request, so a reload
// renders clean: the highlight happens exactly once, only for you.
//
// When the server says the plan was rewritten there are no keys: banding
// the whole page tells you nothing, so the note stands alone and points at
// the history instead.
//
// Slugs are computed here with the same algorithm as the TOC
// (content_nav_controller#slugify) including duplicate -2/-3 suffixes,
// so both sides agree without coordinating on DOM ids.
const TOP_KEY = "__top__"

export default class extends Controller {
  static values = { keys: Array, rewritten: Boolean, historyUrl: String }

  connect() {
    const rendered = this.element.querySelector(".markdown-rendered")
    if (!rendered) return

    if (this.rewrittenValue) {
      this._insertNote(rendered, "Rewritten since you last looked.", true)
      return
    }
    if (this.keysValue.length === 0) return

    const keys = new Set(this.keysValue)
    const used = new Set()
    let marking = keys.has(TOP_KEY)

    // Adjacent changed blocks are banded as one run rather than one box
    // apiece — a section of six paragraphs should read as a single tinted
    // stretch, not six stripes with gaps between them.
    const runs = []
    let run = null

    for (const node of Array.from(rendered.children)) {
      if (/^H[1-3]$/.test(node.tagName)) {
        // Every heading is slugged, changed or not: the `used` set carries
        // the -2/-3 duplicate counter and has to stay in step with Ruby's.
        marking = keys.has(this._slug(node.textContent, used))
      }
      if (!marking) {
        run = null
        continue
      }
      if (!run) {
        run = []
        runs.push(run)
      }
      run.push(node)
    }

    for (const nodes of runs) {
      for (const node of nodes) node.classList.add("section-changed")
      nodes[0].classList.add("section-changed--start")
      nodes[nodes.length - 1].classList.add("section-changed--end")
    }

    if (runs.length > 0) this._insertNote(rendered, "Highlighted sections changed since you last looked.", false)
  }

  _slug(text, used) {
    let base = text
      .toLowerCase()
      .replace(/\s+/g, "-")
      .replace(/[^a-z0-9-]/g, "")
      .replace(/-{2,}/g, "-")
      .replace(/^-|-$/g, "")
    if (base === "") base = "section"
    let slug = base
    let suffix = 2
    while (used.has(slug)) slug = `${base}-${suffix++}`
    used.add(slug)
    return slug
  }

  _insertNote(rendered, text, withHistoryLink) {
    // A Turbo snapshot restore re-runs connect() against cached HTML that
    // already contains the note — don't stack a second one.
    if (this.element.querySelector(".changed-sections-note")) return

    const note = document.createElement("p")
    note.className = "changed-sections-note text-sm text-muted"
    note.innerHTML =
      '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/></svg> '
    note.appendChild(document.createTextNode(text))

    if (withHistoryLink && this.hasHistoryUrlValue) {
      const link = document.createElement("a")
      link.href = this.historyUrlValue
      link.textContent = "See what changed"
      note.appendChild(link)
    }
    rendered.parentNode.insertBefore(note, rendered)
  }
}
