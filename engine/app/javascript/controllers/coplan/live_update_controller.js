import { Controller } from "@hotwired/stimulus"

/*
 * coplan--live-update
 *
 * Listens for the custom <turbo-stream action="coplan-replace-if-clean">
 * payloads broadcast by Broadcaster#replace_plan_content. When an agent
 * (or anyone) commits a new revision elsewhere, the server pushes the new
 * rendered body to every open tab. This controller decides what to do:
 *
 *   * If the user has no unsaved drafts → swap the body in place, then
 *     flash the sections this revision touched (the broadcast carries
 *     their keys in data-changed-sections): changed blocks tint-and-fade,
 *     and plain-text paragraphs get word-level <ins>/<del> flashes so you
 *     can literally watch the agent's edit land.
 *
 *   * If the user is mid-edit (any textarea on the page has non-empty,
 *     non-trim-blank text) → DON'T blow away their typing. Instead, show
 *     a sticky banner above the content: "This plan was updated to
 *     revision N. Reload to see the latest." with a button that reloads.
 *
 * The custom Turbo Stream action is registered exactly once per page —
 * we use a window-level flag so multiple live-update controllers (one per
 * plan body) don't fight each other.
 */
export default class extends Controller {
  static values = {
    revision: Number
  }

  connect() {
    this.constructor.registerStreamAction()
  }

  static registerStreamAction() {
    if (typeof window === "undefined") return
    if (window.__coplanLiveUpdateRegistered) return
    if (typeof window.Turbo === "undefined" || !window.Turbo.StreamActions) {
      // Turbo not ready yet — try again once it loads.
      document.addEventListener("turbo:load", () => this.registerStreamAction(), { once: true })
      return
    }

    window.Turbo.StreamActions["coplan-replace-if-clean"] = function () {
      // `this` is the <turbo-stream> element. Standard Turbo API.
      const targetId = this.getAttribute("target")
      const incomingRevision = parseInt(this.getAttribute("data-revision"), 10) || null
      const target = document.getElementById(targetId)
      if (!target) return

      // If the local DOM is already at this revision (or newer), skip — this
      // tab is the one that issued the edit, no need to re-render.
      const currentRevision = parseInt(target.getAttribute("data-coplan--live-update-revision-value"), 10) || 0
      if (incomingRevision && currentRevision >= incomingRevision) return

      let changedKeys = []
      try {
        // ChangedSections::Result serializes as {"keys": [...], "rewritten": bool}.
        // A full rewrite arrives with no keys, so the swap stays flash-free
        // instead of lighting up the whole document. A bare array is accepted
        // too, in case a not-yet-upgraded server is still broadcasting one.
        const parsed = JSON.parse(this.getAttribute("data-changed-sections") || "[]")
        changedKeys = Array.isArray(parsed) ? parsed : (Array.isArray(parsed?.keys) ? parsed.keys : [])
      } catch { /* malformed attribute — fall back to a flash-free swap */ }

      // `templateContent` is a DocumentFragment — it has no `innerHTML`.
      // Use replaceChildren(fragment) to swap the contents of target in one
      // shot. Stimulus controllers inside target will disconnect + reconnect.
      const fragment = this.templateContent

      if (hasDirtyDrafts()) {
        showStaleBanner(target, incomingRevision)
      } else {
        const oldSections = snapshotSections(target, changedKeys)
        target.replaceChildren(fragment)
        if (incomingRevision) {
          target.setAttribute("data-coplan--live-update-revision-value", String(incomingRevision))
        }
        clearStaleBanner()
        if (changedKeys.length > 0) flashChangedSections(target, changedKeys, oldSections)
      }
    }

    window.__coplanLiveUpdateRegistered = true
  }
}

/*
 * Returns true if ANY textarea or contenteditable on the page contains
 * user-typed text. Used to decide whether it's safe to blow away the
 * rendered body. We're conservative: if even one textarea has trimmed
 * non-empty text, we treat the page as dirty.
 */
function hasDirtyDrafts() {
  const textareas = document.querySelectorAll("textarea")
  for (const ta of textareas) {
    if (ta.value && ta.value.trim().length > 0) return true
  }
  const editables = document.querySelectorAll("[contenteditable='true']")
  for (const el of editables) {
    if (el.textContent && el.textContent.trim().length > 0) return true
  }
  return false
}

/* ---------------------------------------------------------------------
 * Diff flashes. Section boundaries and slugs use the exact walk the
 * changed-sections and TOC controllers use (top-level h1–h3 children of
 * .markdown-rendered, slugified text, -2/-3 duplicate suffixes), so
 * server keys and client sections stay in lockstep.
 */
const TOP_KEY = "__top__"
const FLASH_MS = 2600
const MAX_DIFF_TOKENS = 600

function slugify(text, used) {
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

// Map of section key → array of block elements (live nodes for the new
// DOM; for snapshots we keep outerHTML/text copies instead).
function sectionBlocks(root) {
  const rendered = root.querySelector(".markdown-rendered")
  if (!rendered) return new Map()

  const sections = new Map([[TOP_KEY, []]])
  const used = new Set()
  let currentKey = TOP_KEY

  for (const node of Array.from(rendered.children)) {
    if (/^H[1-3]$/.test(node.tagName)) {
      currentKey = slugify(node.textContent, used)
      sections.set(currentKey, [])
    }
    sections.get(currentKey).push(node)
  }
  return sections
}

function snapshotSections(root, keys) {
  if (!keys || keys.length === 0) return new Map()
  const wanted = new Set(keys)
  const snapshot = new Map()
  for (const [key, blocks] of sectionBlocks(root)) {
    if (!wanted.has(key)) continue
    snapshot.set(key, blocks.map((el) => ({
      tag: el.tagName,
      html: el.outerHTML,
      text: el.textContent,
      plainText: el.childElementCount === 0
    })))
  }
  return snapshot
}

function flashChangedSections(root, keys, oldSections) {
  const wanted = new Set(keys)
  const flashed = []

  for (const [key, blocks] of sectionBlocks(root)) {
    if (!wanted.has(key)) continue
    const oldBlocks = oldSections.get(key) || []
    const oldHtml = new Set(oldBlocks.map((b) => b.html))

    blocks.forEach((block, i) => {
      if (oldHtml.has(block.outerHTML)) return // block untouched

      const old = oldBlocks[i]
      if (
        old && old.tag === block.tagName && old.plainText &&
        block.childElementCount === 0 && blocks.length === oldBlocks.length
      ) {
        renderWordFlash(block, old.text, block.textContent)
      } else {
        block.classList.add("agent-flash-block")
      }
      flashed.push(block)
    })
  }

  if (flashed.length > 0) {
    // Deliberately no scrollIntoView: a remote edit must never move a reader
    // who didn't ask to navigate. On-screen changes flash; off-screen ones
    // settle unseen, and that's fine.
    setTimeout(() => settleFlashes(root), FLASH_MS)
  }
}

// Word-level flash for a plain-text block: rebuild its text as a
// common/inserted/deleted word sequence with <ins>/<del> wrappers. The
// wrappers are temporary — settleFlashes() strips them — so comment
// anchors and copy/paste see clean text again within a couple seconds.
function renderWordFlash(block, oldText, newText) {
  const oldTokens = tokenize(oldText)
  const newTokens = tokenize(newText)
  if (oldTokens.length > MAX_DIFF_TOKENS || newTokens.length > MAX_DIFF_TOKENS) {
    block.classList.add("agent-flash-block")
    return
  }

  block.replaceChildren()
  for (const part of diffTokens(oldTokens, newTokens)) {
    if (part.type === "same") {
      block.appendChild(document.createTextNode(part.text))
    } else {
      const el = document.createElement(part.type === "ins" ? "ins" : "del")
      el.className = "agent-flash"
      el.textContent = part.text
      block.appendChild(el)
    }
  }
}

function tokenize(text) {
  return text.split(/(\s+)/).filter((t) => t.length > 0)
}

// Plain LCS word diff — paragraphs are small, O(n·m) is nothing, and it
// keeps the page dependency-free (no bundler, importmap-only app).
function diffTokens(a, b) {
  const n = a.length, m = b.length
  const lcs = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1])
    }
  }

  const parts = []
  const push = (type, text) => {
    const last = parts[parts.length - 1]
    if (last && last.type === type) last.text += text
    else parts.push({ type, text })
  }

  let i = 0, j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) { push("same", a[i]); i++; j++ }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) { push("del", a[i]); i++ }
    else { push("ins", b[j]); j++ }
  }
  while (i < n) { push("del", a[i]); i++ }
  while (j < m) { push("ins", b[j]); j++ }
  return parts
}

function settleFlashes(root) {
  for (const del of root.querySelectorAll("del.agent-flash")) del.remove()
  for (const ins of root.querySelectorAll("ins.agent-flash")) {
    ins.replaceWith(document.createTextNode(ins.textContent))
  }
  for (const block of root.querySelectorAll(".agent-flash-block")) {
    block.classList.remove("agent-flash-block")
  }
  root.normalize()
}

function showStaleBanner(targetEl, revision) {
  let banner = document.getElementById("plan-stale-banner")
  if (banner) {
    // Already showing — just bump the revision number.
    const span = banner.querySelector("[data-revision]")
    if (span && revision) span.textContent = String(revision)
    return
  }

  banner = document.createElement("div")
  banner.id = "plan-stale-banner"
  banner.className = "plan-stale-banner"
  banner.setAttribute("role", "status")
  banner.setAttribute("aria-live", "polite")
  banner.innerHTML = `
    <div class="plan-stale-banner__message">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>
      This plan was updated${revision ? ` (now at revision <strong data-revision>${revision}</strong>)` : ""}.
      Your draft is preserved here — reload to see the latest version.
    </div>
    <button type="button" class="btn btn--primary btn--sm plan-stale-banner__reload">Reload</button>
  `
  banner.querySelector(".plan-stale-banner__reload").addEventListener("click", () => {
    window.location.reload()
  })

  // Insert directly above the stale content so the connection is visually obvious.
  targetEl.parentNode.insertBefore(banner, targetEl)
}

function clearStaleBanner() {
  const banner = document.getElementById("plan-stale-banner")
  if (banner) banner.remove()
}
