import { Controller } from "@hotwired/stimulus"
import { commandFor } from "coplan/shortcuts"

const URI_SCHEME = /^[a-z][a-z0-9+.-]*:/i
const UNSAFE_SCHEME = /^(javascript|vbscript|data|blob):/i
const linkUri = value => URI_SCHEME.test(value) && !UNSAFE_SCHEME.test(value) && !/[\s\u0000-\u001f\u007f]/.test(value)

// Comment-form behavior: submit-on-Enter (Shift+Enter for newline) plus an
// inline @-mention picker. The picker activates when the user types `@` at a
// word boundary inside the textarea, fetches matches from /users/search, and
// inserts `[@username](mention:username)` markdown on selection. Mod+K and
// pasting a URL over a selection write Markdown links.
//
// Both behaviors live on the same controller so submit-on-Enter can defer to
// the picker when it's open (Enter selects the highlighted user instead of
// submitting the form).
export default class extends Controller {
  // Search URL is supplied per-form via a Stimulus value so it respects the
  // engine's mount point (host apps may mount Coplan under e.g. `/coplan`).
  // The default is fine for hosts that mount at root.
  static targets = ["input", "draft", "linkPanel", "linkUrl", "linkLabel", "linkError", "linkResults"]

  static values = {
    searchUrl: { type: String, default: "/users/search" },
    linkSearchUrl: String
  }

  connect() {
    this._picker = null
    this._results = []
    this._highlightIndex = -1
    this._triggerStart = -1 // index of the `@` in the textarea value
    this._debounce = null
    this._docClickHandler = this.handleDocumentClick.bind(this)
    this._inputHandler = this.handleInput.bind(this)
    this._keydownHandler = this.handleKeydown.bind(this)
    this._submitEndHandler = this.handleSubmitEnd.bind(this)

    this.inputTarget.addEventListener("input", this._inputHandler)
    // keydown listens with capture so the picker handles Enter/Arrows
    // before anything else on the page sees them.
    this.inputTarget.addEventListener("keydown", this._keydownHandler, true)
    document.addEventListener("click", this._docClickHandler)

    // Notify the global Web Push encouragement banner that this user just
    // posted a comment — gives the banner a chance to surface itself.
    this._submitForm = this.inputTarget.closest("form")
    if (this._submitForm) {
      this._submitForm.addEventListener("turbo:submit-end", this._submitEndHandler)
    }
  }

  disconnect() {
    this.inputTarget.removeEventListener("input", this._inputHandler)
    this.inputTarget.removeEventListener("keydown", this._keydownHandler, true)
    document.removeEventListener("click", this._docClickHandler)
    if (this._submitForm) {
      this._submitForm.removeEventListener("turbo:submit-end", this._submitEndHandler)
    }
    this.closeLink()
    this.closePicker()
    if (this._debounce) clearTimeout(this._debounce)
    this._fetchAbort?.abort()
  }

  handleSubmitEnd(event) {
    if (!event.detail?.success) return
    document.dispatchEvent(new CustomEvent("coplan:web-push-banner:nudge"))
  }

  handleKeydown(event) {
    if (this.pickerOpen()) {
      if (event.key === "ArrowDown") {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.moveHighlight(1)
        return
      }
      if (event.key === "ArrowUp") {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.moveHighlight(-1)
        return
      }
      if ((event.key === "Enter" || event.key === "Tab") && !event.isComposing) {
        if (this._highlightIndex >= 0 && this._results[this._highlightIndex]) {
          event.preventDefault()
          event.stopImmediatePropagation()
          this.selectResult(this._results[this._highlightIndex])
          return
        }
      }
      if (event.key === "Escape") {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.closePicker()
        return
      }
    }

    // Submit-on-Enter (only when picker is closed).
    if (commandFor("reply", event) === "submit") {
      const form = this.inputTarget.closest("form")
      if (!form) return
      event.preventDefault()
      if (this.inputTarget.closest('[data-dictation-busy="true"]')) return
      const submitter = form.querySelector('[type="submit"]')
      if (submitter?.disabled) return
      form.requestSubmit(submitter)
    }
  }

  // Keep the selection while the in-app URL field has focus.
  link(event) {
    if (commandFor("reply", event) !== "link") return
    event.preventDefault()
    event.stopPropagation()
    if (this._debounce) clearTimeout(this._debounce)
    this._fetchAbort?.abort()
    this.closePicker()
    const { selectionStart: start, selectionEnd: end, value } = this.inputTarget
    this._linkSelection = { start, end, value }
    this.linkUrlTarget.value = ""
    this.clearLinkError()
    this.draftTarget.inert = true
    this.linkPanelTarget.hidden = false
    this.linkPanelTarget.showPopover()
    this.linkResultsTarget.textContent = "Search plans and people, or paste a link."
    this.positionLink()
    this.linkUrlTarget.focus({ preventScroll: true })
  }

  positionLink() {
    if (this.linkPanelTarget.hidden) return
    const anchor = this.inputTarget.getBoundingClientRect()
    const panel = this.linkPanelTarget
    const width = Math.min(340, innerWidth - 24)
    panel.style.width = `${width}px`
    const height = panel.getBoundingClientRect().height
    const beside = innerWidth - anchor.right >= width + 20
    const left = beside ? anchor.right + 8 : Math.min(anchor.left, innerWidth - width - 12)
    const top = beside ? anchor.top : (innerHeight - anchor.bottom >= height + 20 ? anchor.bottom + 8 : anchor.top - height - 8)
    Object.assign(panel.style, { left: `${Math.max(12, left)}px`, top: `${Math.max(12, Math.min(top, innerHeight - height - 12))}px` })
  }

  searchLinks() {
    this.clearLinkError()
    clearTimeout(this._linkDebounce)
    this._linkAbort?.abort()
    const query = this.linkUrlTarget.value.trim()
    if (!query || URI_SCHEME.test(query)) {
      this.linkResultsTarget.textContent = query ? "" : "Search plans and people, or paste a link."
      this.positionLink()
      return
    }
    this.linkResultsTarget.textContent = "Searching…"
    this._linkDebounce = setTimeout(() => this.fetchLinks(query), 180)
  }

  async fetchLinks(query) {
    const request = new AbortController()
    this._linkAbort = request
    const url = new URL(this.linkSearchUrlValue, location.href)
    url.searchParams.set("q", query)
    url.searchParams.set("frame", "links")
    try {
      const response = await fetch(url, { signal: request.signal, headers: { Accept: "text/html" } })
      if (!response.ok || response.redirected) throw new Error("Search unavailable")
      const html = await response.text()
      if (request.signal.aborted || this.linkPanelTarget.hidden) return
      this.linkResultsTarget.innerHTML = html
    } catch (error) {
      if (error.name === "AbortError") return
      this.linkResultsTarget.textContent = "Search unavailable. You can still paste a link."
    }
    this.positionLink()
  }

  selectLink(event) {
    const { linkHref, linkTitle } = event.currentTarget.dataset
    this.linkUrlTarget.value = new URL(linkHref, location.href).href
    this.applyLink(linkTitle)
  }

  linkKeydown(event) {
    // Do not let Enter submit the comment or Escape close its window.
    event.stopPropagation()
    if (event.isComposing) return
    if (event.key === "Escape") {
      event.preventDefault()
      this.cancelLink()
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      const results = [...this.linkResultsTarget.querySelectorAll("button")]
      if (!results.length) return
      event.preventDefault()
      const index = results.indexOf(event.target)
      const next = event.key === "ArrowDown" ? index + 1 : (index < 0 ? results.length - 1 : index - 1)
      results[(next + results.length) % results.length].focus({ preventScroll: true })
      results[(next + results.length) % results.length].scrollIntoView({ block: "nearest" })
    } else if (event.key === "Enter" && event.target === this.linkUrlTarget) {
      event.preventDefault()
      const result = this.linkResultsTarget.querySelector("button")
      if (!URI_SCHEME.test(this.linkUrlTarget.value.trim()) && result) result.click()
      else this.applyLink()
    }
  }

  clearLinkError() {
    this.linkErrorTarget.hidden = true
    this.linkLabelTarget.hidden = false
    this.linkUrlTarget.removeAttribute("aria-invalid")
  }

  showLinkError(message) {
    this.linkErrorTarget.textContent = message
    this.linkErrorTarget.hidden = false
    this.linkLabelTarget.hidden = true
    this.linkUrlTarget.setAttribute("aria-invalid", "true")
    this.linkUrlTarget.focus({ preventScroll: true })
  }

  applyLink(suggestedLabel) {
    const href = this.linkUrlTarget.value.trim()
    if (!linkUri(href)) {
      this.showLinkError("Enter a URI such as https://… or codex://… without spaces.")
      return
    }
    const selection = this._linkSelection
    // Dictation can update the draft while this field has focus. Keep the
    // URL available and explain why the original selection is no longer safe.
    if (!selection || this.inputTarget.value !== selection.value) {
      this.showLinkError("Draft changed. Cancel and reselect text.")
      return
    }
    this.cancelLink()
    const label = selection.value.slice(selection.start, selection.end) || (typeof suggestedLabel === "string" ? suggestedLabel : "")
    this.insertLink(label, href)
    if (!label) this.inputTarget.setSelectionRange(selection.start + 1, selection.start + 1)
  }

  composerClosed(event) {
    if (!event.target.contains(this.element)) return
    this.closeLink()
    this._linkSelection = null
  }

  closeLink() {
    clearTimeout(this._linkDebounce)
    this._linkAbort?.abort()
    if (this.linkPanelTarget.matches(":popover-open")) this.linkPanelTarget.hidePopover()
    this.linkPanelTarget.hidden = true
    this.draftTarget.inert = false
  }

  cancelLink() {
    this.closeLink()
    this.inputTarget.focus({ preventScroll: true })
    if (this._linkSelection && this.inputTarget.value === this._linkSelection.value) {
      this.inputTarget.setSelectionRange(this._linkSelection.start, this._linkSelection.end)
    }
    this._linkSelection = null
  }

  pasteLink(event) {
    const { selectionStart: start, selectionEnd: end, value } = this.inputTarget
    const href = event.clipboardData?.getData("text/plain").trim()
    const label = value.slice(start, end)
    if (!label || !linkUri(href) || URI_SCHEME.test(label.trim())) return
    event.preventDefault()
    this.insertLink(label, href)
  }

  insertLink(label, href) {
    // Escape backslashes together with delimiters so literal prose and URL
    // punctuation survive CommonMark parsing when the comment is posted.
    const escapedLabel = label.replace(/[\\\[\]]/g, "\\$&")
    const escapedHref = href.replace(/[\\()]/g, "\\$&")
    this.insertText(`[${escapedLabel}](${escapedHref})`)
  }

  // insertText keeps the edit on the browser's undo stack and fires input.
  insertText(text) {
    if (document.execCommand("insertText", false, text)) return
    this.inputTarget.setRangeText(text, this.inputTarget.selectionStart, this.inputTarget.selectionEnd, "end")
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  handleInput(_event) {
    const trigger = this.detectMentionTrigger()
    if (!trigger) {
      this.closePicker()
      return
    }

    this._triggerStart = trigger.start
    const query = trigger.query

    if (this._debounce) clearTimeout(this._debounce)

    if (query.length === 0) {
      // Just typed `@` — show no results yet, but reserve the slot so
      // typing one more char shows the picker immediately.
      this.closePicker()
      return
    }

    this._debounce = setTimeout(() => this.fetchResults(query), 150)
  }

  detectMentionTrigger() {
    const ta = this.inputTarget
    const caret = ta.selectionStart
    if (caret !== ta.selectionEnd) return null
    const value = ta.value
    // Walk backwards from caret to find `@` at a word boundary.
    let i = caret - 1
    while (i >= 0) {
      const ch = value[i]
      if (ch === "@") {
        const before = i === 0 ? " " : value[i - 1]
        // Must be at start-of-text or preceded by whitespace/punctuation.
        if (/[\s(\[]/.test(before) || i === 0) {
          const query = value.slice(i + 1, caret)
          // Bail if the in-progress query contains whitespace or markdown chars.
          if (/[\s\]\)]/.test(query)) return null
          return { start: i, query }
        }
        return null
      }
      // Stop if we hit whitespace before finding `@`.
      if (/\s/.test(ch)) return null
      i--
    }
    return null
  }

  async fetchResults(query) {
    // Abort any in-flight search — a slow earlier response must not
    // overwrite the results of a faster later one.
    this._fetchAbort?.abort()
    this._fetchAbort = new AbortController()
    try {
      const response = await fetch(`${this.searchUrlValue}?q=${encodeURIComponent(query)}`, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal: this._fetchAbort.signal,
      })
      if (!response.ok) {
        this.closePicker()
        return
      }
      const users = await response.json()
      this._results = users || []
      this._highlightIndex = this._results.length > 0 ? 0 : -1
      this.renderPicker()
    } catch (err) {
      if (err.name === "AbortError") return
      console.error("[mention-picker] fetch failed", err)
      this.closePicker()
    }
  }

  renderPicker() {
    if (!this._picker) {
      this._picker = document.createElement("ul")
      this._picker.className = "mention-picker"
      this._picker.setAttribute("role", "listbox")
      // A nested top-layer picker can extend beyond the glass window.
      const host = this.inputTarget.closest(".comment-window") || document.body
      host.appendChild(this._picker)
      if (host !== document.body) {
        this._picker.setAttribute("popover", "manual")
        Object.assign(this._picker.style, { position: "fixed", margin: "0", inset: "auto" })
      }
    }

    this._picker.innerHTML = ""

    if (this._results.length === 0) {
      const empty = document.createElement("li")
      empty.className = "mention-picker__empty"
      empty.textContent = "No matches"
      this._picker.appendChild(empty)
    } else {
      this._results.forEach((user, idx) => {
        const li = document.createElement("li")
        li.className = "mention-picker__item"
        if (!user.username) li.classList.add("mention-picker__item--disabled")
        if (idx === this._highlightIndex) li.classList.add("mention-picker__item--highlighted")
        li.dataset.index = idx

        const name = document.createElement("span")
        name.className = "mention-picker__name"
        name.textContent = user.username ? `${user.name} · @${user.username}` : (user.name || "(unnamed)")
        li.appendChild(name)

        const metaParts = [user.title, user.team, user.email].filter(Boolean)
        if (!user.username) metaParts.unshift("no username — can't mention")
        if (metaParts.length) {
          const meta = document.createElement("span")
          meta.className = "mention-picker__meta"
          meta.textContent = metaParts.join(" · ")
          li.appendChild(meta)
        }

        li.addEventListener("mousedown", (e) => {
          e.preventDefault() // keep textarea focus
          if (!user.username) return
          this.selectResult(user)
        })
        li.addEventListener("mouseenter", () => {
          this._highlightIndex = idx
          this.applyHighlight()
        })

        this._picker.appendChild(li)
      })
    }

    this._picker.hidden = false
    if (this._picker.hasAttribute("popover") && !this._picker.matches(":popover-open")) this._picker.showPopover()
    this.positionPicker()
  }

  applyHighlight() {
    if (!this._picker) return
    const items = this._picker.querySelectorAll(".mention-picker__item")
    items.forEach((el, i) => {
      el.classList.toggle("mention-picker__item--highlighted", i === this._highlightIndex)
    })
  }

  moveHighlight(delta) {
    if (this._results.length === 0) return
    this._highlightIndex = (this._highlightIndex + delta + this._results.length) % this._results.length
    this.applyHighlight()
    const items = this._picker?.querySelectorAll(".mention-picker__item") || []
    items[this._highlightIndex]?.scrollIntoView({ block: "nearest" })
  }

  positionPicker() {
    if (!this._picker) return
    const rect = this.inputTarget.getBoundingClientRect()
    const fixed = this._picker.hasAttribute("popover")
    const top = Math.max(12, Math.min(rect.bottom + 4, window.innerHeight - this._picker.offsetHeight - 12))
    this._picker.style.top = `${fixed ? top : window.scrollY + top}px`
    this._picker.style.left = `${fixed ? rect.left : window.scrollX + rect.left}px`
    this._picker.style.minWidth = `${Math.min(rect.width, 360)}px`
  }

  selectResult(user) {
    if (!user || !user.username) {
      this.closePicker()
      return
    }
    const ta = this.inputTarget
    const caret = ta.selectionStart
    const before = ta.value.slice(0, this._triggerStart)
    const after = ta.value.slice(caret)
    // Insert plain `@username ` — the server rewrites it to the canonical
    // `[@username](mention:username)` form on save, so the textarea stays
    // clean while editing.
    const insertion = `@${user.username} `
    ta.value = `${before}${insertion}${after}`
    const newCaret = (before + insertion).length
    ta.setSelectionRange(newCaret, newCaret)
    ta.dispatchEvent(new Event("input", { bubbles: true }))
    ta.focus()
    this.closePicker()
  }

  closePicker() {
    if (this._picker) {
      this._picker.remove()
      this._picker = null
    }
    this._results = []
    this._highlightIndex = -1
    this._triggerStart = -1
  }

  pickerOpen() {
    return this._picker !== null && !this._picker.hidden
  }

  handleDocumentClick(event) {
    if (!this.linkPanelTarget.hidden && !this.linkPanelTarget.contains(event.target)) this.cancelLink()
    if (!this._picker) return
    if (this._picker.contains(event.target)) return
    if (event.target === this.inputTarget) return
    this.closePicker()
  }
}
