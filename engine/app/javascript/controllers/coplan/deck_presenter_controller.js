import { Controller } from "@hotwired/stimulus"

/*
 * coplan--deck-presenter
 *
 * Present mode: the deck takes the screen as one 16:9 canvas — exactly what
 * a Zoom or Meet screen-share needs. One slide shows at a time; arrows,
 * space, page keys, and clicks advance; Escape (or leaving native
 * fullscreen) ends the show. Native fullscreen is requested on this
 * wrapper, with the fixed-overlay CSS as the fallback when the browser
 * refuses, so presenting works either way.
 *
 * The wrapper sits OUTSIDE the live-update swap target: an edit landing
 * mid-presentation replaces the deck underneath without disconnecting this
 * controller. Every entry point re-acquires the current deck by lookup, and
 * a childList observer re-applies the presenting state to a freshly swapped
 * deck so the show survives collaboration.
 */
export default class extends Controller {
  connect() {
    this.presenting = false
    this.index = 0
    this._onKeydown = this._handleKeydown.bind(this)
    this._onClick = this._handleClick.bind(this)
    this._onMouseUp = this._handleMouseUp.bind(this)
    this._onFullscreenChange = this._handleFullscreenChange.bind(this)
    // Turbo snapshots the page before controllers disconnect; a cached
    // mid-show deck would restore wearing a closed popover attribute —
    // display: none, an invisible plan. End the show before the snapshot.
    this._onBeforeCache = () => this.stop()
    // Capture phase: while presenting, the show owns the keyboard —
    // Backspace pages backward instead of triggering plan-keys' go-back.
    document.addEventListener("keydown", this._onKeydown, true)
    document.addEventListener("fullscreenchange", this._onFullscreenChange)
    document.addEventListener("turbo:before-cache", this._onBeforeCache)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown, true)
    document.removeEventListener("fullscreenchange", this._onFullscreenChange)
    document.removeEventListener("turbo:before-cache", this._onBeforeCache)
    this._teardown()
  }

  start() {
    if (this.presenting || !this._acquireDeck()) return

    this.presenting = true
    // Lock the page behind the show — a wheel over the letterbox must not
    // scroll the plan out from under the presenter.
    this._pageOverflow = document.documentElement.style.overflow
    document.documentElement.style.overflow = "hidden"
    document.addEventListener("click", this._onClick, true)
    document.addEventListener("mouseup", this._onMouseUp, true)
    // A comment thread popover left open on the page must not float above
    // the show.
    this._dismissForeignPopovers()
    this.observer = new MutationObserver(() => {
      if (this.presenting && this.element.querySelector(".deck") !== this.deck) this._show(this.index)
    })
    this.observer.observe(this.element, { childList: true, subtree: true })

    const resumed = window.location.hash.match(/^#present-(\d+)$/)
    // Presenting borrows the URL fragment for #present-N; remember what
    // was there (a heading deep link, a footnote) to give back on exit.
    this._priorHash = resumed ? "" : window.location.hash
    this._peeling = false
    this._show(resumed ? Number(resumed[1]) - 1 : 0)
    // _show stops the show itself on a slideless deck — don't take the
    // screen for nothing.
    if (!this.presenting) return

    // Move focus into the show. Clicking the Present button leaves the
    // button focused, and a focused control outside the deck would
    // otherwise soak up the navigation keys.
    this._trigger = document.activeElement
    const deck = this.element.querySelector(".deck")
    if (deck) {
      deck.tabIndex = -1
      deck.focus({ preventScroll: true })
    }

    // Native fullscreen when the browser grants it; the top-layer popover
    // (see _promoteDeck) is what actually fills the screen either way.
    // Re-promote once fullscreen resolves — the fullscreen wrapper enters
    // the top layer above the already-shown popover and would cover it.
    this.element.requestFullscreen?.().then(() => {
      // The grant can outlive a fast Escape: if the show already ended,
      // give the screen back instead of re-promoting a stopped deck.
      if (!this.presenting) {
        if (document.fullscreenElement === this.element) document.exitFullscreen().catch(() => {})
        return
      }
      this._promoteDeck(true)
    }).catch(() => {})
  }

  stop() {
    if (!this.presenting) return

    this.presenting = false
    this._teardown()
    if (document.fullscreenElement === this.element) document.exitFullscreen().catch(() => {})
    if (window.location.hash.startsWith("#present-")) {
      history.replaceState(history.state, "", window.location.pathname + window.location.search + (this._priorHash || ""))
    }
  }

  _show(index) {
    const deck = this._acquireDeck()
    const slides = deck ? this._slides(deck) : []
    if (slides.length === 0) return this.stop()

    this.index = Math.max(0, Math.min(index, slides.length - 1))
    deck.classList.add("deck--presenting")
    this._promoteDeck()
    slides.forEach((slide, i) => slide.classList.toggle("deck-slide--current", i === this.index))
    slides[this.index].scrollTop = 0
    history.replaceState(history.state, "", `#present-${this.index + 1}`)
  }

  // The show must escape the page: an ancestor with backdrop-filter (the
  // plan's glass .card) is the containing block for position: fixed, which
  // would trap the overlay at the card's size and stacking level. Top-layer
  // elements position against the viewport no matter their ancestors, so
  // the deck presents as a manual popover — in the fallback path and under
  // native fullscreen alike.
  _promoteDeck(force = false) {
    const deck = this.element.querySelector(".deck")
    if (!deck || !this.presenting || !deck.showPopover) return

    deck.popover = "manual"
    if (deck.matches(":popover-open")) {
      if (!force) return
      deck.hidePopover()
    }
    deck.showPopover()
  }

  _acquireDeck() {
    const deck = this.element.querySelector(".deck")
    if (deck && deck !== this.deck) {
      this.deck = deck
      const slides = this._slides(deck)
      slides.forEach(slide => (slide.dataset.slideTotal = slides.length))
    }
    return deck
  }

  _slides(deck) {
    return Array.from(deck.querySelectorAll(":scope > section.deck-slide"))
  }

  _handleKeydown(event) {
    // A modal (the mermaid lightbox) owns its own keys.
    if (event.target.closest?.("dialog")) return
    if (event.metaKey || event.ctrlKey || event.altKey) {
      // Modifier chords aren't the show's to handle, but mid-show the
      // page's own hotkeys must still be starved — Ctrl+Space (or held
      // Alt) would start a voice recording invisibly behind the overlay.
      // Text entry above the show keeps its shortcuts (Cmd+Enter submits
      // a reply); browser chords (reload, find, copy) ignore propagation.
      if (this.presenting && !this._typing(event.target)) event.stopPropagation()
      return
    }

    if (!this.presenting) {
      if (event.key !== "p" || this._typing(event.target)) return
      if (!this.element.querySelector(".deck")) return
      event.preventDefault()
      this.start()
      return
    }

    // The keyboard mirror of the click pass-through below: a focused
    // control owns the keys it actually responds to — Space toggles the
    // checkbox it sits on — while keys a control ignores (arrows, paging)
    // keep driving the show. Escape stays the exit everywhere.
    if (event.key !== "Escape" && this._claimsKey(event.target, event.key)) return

    switch (event.key) {
      case "ArrowRight":
      case "ArrowDown":
      case "PageDown":
      case " ":
        this._navigate(event, this.index + 1)
        break
      case "ArrowLeft":
      case "ArrowUp":
      case "PageUp":
      case "Backspace":
        this._navigate(event, this.index - 1)
        break
      case "Home":
        this._navigate(event, 0)
        break
      case "End":
        this._navigate(event, Infinity)
        break
      case "Escape":
        event.preventDefault()
        event.stopPropagation()
        // A popover above the show (a reference preview, a pinned thread)
        // is what Escape visibly targets — dismiss it and keep presenting;
        // only a bare Escape ends the show. The browser may drop native
        // fullscreen on this same keypress (that exit is uncancelable), so
        // mark the peel: the resulting fullscreenchange is forgiven and
        // the show continues on the top-layer fallback.
        if (this._dismissForeignPopovers()) {
          if (document.fullscreenElement === this.element) this._peeling = true
          return
        }
        this.stop()
        break
      default:
        // The page behind the show is invisible; its shortcut handlers
        // (comment j/k navigation, section jumps) must not fire under the
        // presentation. Propagation stops here — browser defaults (Tab,
        // find, reload) are untouched.
        event.stopPropagation()
    }
  }

  // Closes any open popover that isn't the presented deck. Returns whether
  // anything was dismissed.
  _dismissForeignPopovers() {
    const deck = this.element.querySelector(".deck")
    let dismissed = false
    document.querySelectorAll(":popover-open").forEach(popover => {
      if (popover === deck) return
      try { popover.hidePopover() } catch {}
      dismissed = true
    })
    return dismissed
  }

  _navigate(event, index) {
    event.preventDefault()
    event.stopPropagation()
    this._show(index)
  }

  _handleClick(event) {
    if (!this.presenting) return
    if (event.target.closest?.("dialog")) return

    const deck = this.element.querySelector(".deck")
    const onCanvas = deck && deck.contains(event.target)

    // A popover above the show (reference preview, a pinned thread) is
    // visible UI, not hidden page — its buttons and links keep working.
    const popover = event.target.closest?.("[popover]")
    if (popover && popover !== deck && popover.matches(":popover-open")) return

    // A same-document link mid-show: the target's slide is display: none,
    // so the browser's fragment jump would show nothing — and would clobber
    // the #present-N resume hash. Navigate the show to the slide that owns
    // the target instead; targets outside the deck (the footnote back
    // matter, hidden behind the overlay) are swallowed as no-ops.
    const anchor = onCanvas && event.target.closest('a[href^="#"]')
    if (anchor) {
      event.preventDefault()
      event.stopPropagation()
      let id = anchor.getAttribute("href").slice(1)
      try { id = decodeURIComponent(id) } catch {}
      const target = id ? deck.querySelector(`#${CSS.escape(id)}`) : null
      const slide = target?.closest("section.deck-slide")
      if (slide) {
        this._show(this._slides(deck).indexOf(slide))
        target.scrollIntoView({ block: "nearest" })
      }
      return
    }

    // Links, checkboxes, and buttons on a slide still work; everything
    // else — canvas, letterbox, the page hidden behind the overlay —
    // advances (and is swallowed so hidden controls can't be hit).
    if (onCanvas && event.target.closest("a, button, input, textarea, summary, [contenteditable]")) return

    event.preventDefault()
    event.stopPropagation()
    this._show(this.index + 1)
  }

  // text-selection offers "comment on this selection" from mouseup on the
  // content target — mid-show that affordance would pop over the deck.
  // Starve the listener; native click synthesis is unaffected, so slide
  // links and checkboxes still work.
  _handleMouseUp(event) {
    if (!this.presenting) return
    if (event.target.closest?.("dialog")) return

    event.stopPropagation()
  }

  _handleFullscreenChange() {
    if (!this.presenting || document.fullscreenElement) return

    // One exit is forgiven when Escape was consumed dismissing a popover —
    // the keypress was aimed at the popover, not the show.
    if (this._peeling) {
      this._peeling = false
      return
    }
    this.stop()
  }

  _typing(target) {
    const tag = target.tagName
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || target.isContentEditable
  }

  // Which keys a focused element keeps from the show, per what the control
  // actually responds to. Text entry owns every key wherever it lives (the
  // only text fields reachable mid-show sit in popovers above the deck);
  // toggles own just their activation keys; buttons qualify only on the
  // canvas — the Present button outside it owns nothing.
  _claimsKey(target, key) {
    if (target.isContentEditable) return true
    const tag = target.tagName
    if (tag === "TEXTAREA" || tag === "SELECT") return true
    if (tag === "INPUT") {
      const type = (target.type || "").toLowerCase()
      if (type === "checkbox" || type === "radio") return key === " " || key === "Enter"
      return true
    }
    if (tag === "BUTTON" || tag === "SUMMARY") {
      return (key === " " || key === "Enter") && !!this.element.querySelector(".deck")?.contains(target)
    }
    return false
  }

  _teardown() {
    document.removeEventListener("click", this._onClick, true)
    document.removeEventListener("mouseup", this._onMouseUp, true)
    if (this._pageOverflow !== undefined) {
      document.documentElement.style.overflow = this._pageOverflow
      this._pageOverflow = undefined
    }
    this.observer?.disconnect()
    this.observer = null
    // Hand focus back to whatever launched the show (usually the Present
    // button) — before the deck lookup, because the one case where focus
    // was forcibly lost is exactly the deck being swapped away.
    if (this._trigger?.isConnected) this._trigger.focus?.({ preventScroll: true })
    this._trigger = null
    const deck = this.element.querySelector(".deck")
    if (!deck) return

    deck.classList.remove("deck--presenting")
    deck.removeAttribute("tabindex")
    deck.querySelectorAll(".deck-slide--current").forEach(slide => slide.classList.remove("deck-slide--current"))
    // A closed popover is display: none — the attribute must go too, or
    // the deck vanishes from the page after the show.
    if (deck.matches("[popover]")) {
      if (deck.matches(":popover-open")) deck.hidePopover()
      deck.removeAttribute("popover")
    }
  }
}
