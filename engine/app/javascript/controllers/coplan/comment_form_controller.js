import { Controller } from "@hotwired/stimulus"

// Comment-form behavior: submit-on-Enter (Shift+Enter for newline) plus an
// inline @-mention picker. The picker activates when the user types `@` at a
// word boundary inside the textarea, fetches matches from /users/search, and
// inserts `[@username](mention:username)` markdown on selection.
//
// Both behaviors live on the same controller so submit-on-Enter can defer to
// the picker when it's open (Enter selects the highlighted user instead of
// submitting the form).
export default class extends Controller {
  // Search URL is supplied per-form via a Stimulus value so it respects the
  // engine's mount point (host apps may mount CoPlan under e.g. `/coplan`).
  // The default is fine for hosts that mount at root.
  static values = {
    searchUrl: { type: String, default: "/users/search" }
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

    this.element.addEventListener("input", this._inputHandler)
    // keydown listens with capture so the picker handles Enter/Arrows
    // before the legacy submitOnEnter action fires.
    this.element.addEventListener("keydown", this._keydownHandler, true)
    document.addEventListener("click", this._docClickHandler)
  }

  disconnect() {
    this.element.removeEventListener("input", this._inputHandler)
    this.element.removeEventListener("keydown", this._keydownHandler, true)
    document.removeEventListener("click", this._docClickHandler)
    this.closePicker()
    if (this._debounce) clearTimeout(this._debounce)
  }

  // Legacy keep-alive entry point (still wired in views via data-action).
  // Real Enter handling now happens in handleKeydown.
  submitOnEnter(_event) {}

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
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      const form = this.element.closest("form")
      if (!form) return
      event.preventDefault()
      form.requestSubmit()
    }
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
    const ta = this.element
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
    try {
      const response = await fetch(`${this.searchUrlValue}?q=${encodeURIComponent(query)}`, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
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
      console.error("[mention-picker] fetch failed", err)
      this.closePicker()
    }
  }

  renderPicker() {
    if (!this._picker) {
      this._picker = document.createElement("ul")
      this._picker.className = "mention-picker"
      this._picker.setAttribute("role", "listbox")
      // Append to body so it can overflow form/card boundaries.
      document.body.appendChild(this._picker)
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

    this.positionPicker()
    this._picker.hidden = false
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
    const rect = this.element.getBoundingClientRect()
    this._picker.style.top = `${window.scrollY + rect.bottom + 4}px`
    this._picker.style.left = `${window.scrollX + rect.left}px`
    this._picker.style.minWidth = `${Math.min(rect.width, 360)}px`
  }

  selectResult(user) {
    if (!user || !user.username) {
      this.closePicker()
      return
    }
    const ta = this.element
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
    if (!this._picker) return
    if (this._picker.contains(event.target)) return
    if (event.target === this.element) return
    this.closePicker()
  }
}
