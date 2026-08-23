/*
 * DeckInk — the presenter's pen.
 *
 * Mid-show, `d` arms the pen: a drag paints over the slide instead of
 * selecting text, and each stroke fades out on its own a couple of seconds
 * after it lands. Ink is a gesture in the room, not an edit — nothing is
 * saved, nothing is broadcast, there is no undo, and the slide cleans
 * itself up. A laser pointer with a short memory.
 *
 * Owned by coplan--deck-presenter, which arbitrates the gestures around it
 * (a drag never also pages forward) and stows the pen when the show ends.
 */

const SVG_NS = "http://www.w3.org/2000/svg"

// A stroke holds, then fades; deck-ink-fade owns the curve. Mirrored here
// so the node still gets reaped where that animation never runs — a
// reduced-motion setting, a test run with animations off.
const STROKE_LIFE_MS = 2600
// Pointer travel below this doesn't move the pen. Dropping those samples
// keeps the path short enough to re-serialize at pointer rate.
const MIN_STEP = 2
// A press that never travels this far was a tap: the presenter asking for
// the next slide, not drawing. A stray dot would read as a glitch.
const MIN_TRAVEL = 4
// Pen weight as a fraction of canvas width, so the mark is the same weight
// on a laptop and on a projector.
const STROKE_RATIO = 0.005

// Pen-out indicator. Glyph only: this lives inside the comment-anchor
// content target, which counts occurrences of the visible text under it, so
// the key hint is pseudo-element content in CSS instead of a text node.
const BADGE_HTML = `
  <div class="deck-ink-badge" aria-hidden="true">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M16.4 3.6a2.2 2.2 0 0 1 3 3L7.4 18.6l-4.4 1.4 1.4-4.4z"/>
    </svg>
  </div>`

const round = value => Math.round(value * 10) / 10

// Quadratic through the midpoints between samples: the recorded points
// become control points, so the line curves through a fast scribble instead
// of showing every polygon corner. Never called with fewer than two points
// — a stroke only gets a path once it has travelled.
const pathData = points => {
  let data = `M ${round(points[0].x)} ${round(points[0].y)}`
  for (let i = 1; i < points.length - 1; i++) {
    const point = points[i]
    const next = points[i + 1]
    data += ` Q ${round(point.x)} ${round(point.y)} ${round((point.x + next.x) / 2)} ${round((point.y + next.y) / 2)}`
  }
  const last = points[points.length - 1]
  return `${data} L ${round(last.x)} ${round(last.y)}`
}

export class DeckInk {
  // wrapper: the .deck-presenter element. The deck inside it is replaced
  // wholesale when a collaborator's edit lands mid-show, so every entry
  // point re-acquires it (and re-creates the layer) instead of holding a
  // reference across the swap.
  constructor(wrapper) {
    this.wrapper = wrapper
    this.armed = false
    this.stroke = null
    this.painted = false
    this._reapers = new Set()
    this._onPointerDown = this._handlePointerDown.bind(this)
    this._onPointerMove = this._handlePointerMove.bind(this)
    this._onPointerEnd = this._handlePointerEnd.bind(this)
  }

  toggle() {
    this.armed ? this.stow() : this.arm()
  }

  arm() {
    if (this.armed) return

    this.armed = true
    // Capture phase on the document: a stroke must not depend on what the
    // pointer happens to be over, and slide content (links, checkboxes,
    // a diagram's expand chip) must not swallow the press.
    document.addEventListener("pointerdown", this._onPointerDown, true)
    document.addEventListener("pointermove", this._onPointerMove, true)
    document.addEventListener("pointerup", this._onPointerEnd, true)
    document.addEventListener("pointercancel", this._onPointerEnd, true)
    this._dress()
  }

  stow() {
    if (!this.armed) return

    this._endStroke()
    this.armed = false
    document.removeEventListener("pointerdown", this._onPointerDown, true)
    document.removeEventListener("pointermove", this._onPointerMove, true)
    document.removeEventListener("pointerup", this._onPointerEnd, true)
    document.removeEventListener("pointercancel", this._onPointerEnd, true)
    this.wrapper.querySelector(".deck")?.classList.remove("deck--inking")
    this.wrapper.querySelectorAll(".deck-ink-badge").forEach(badge => badge.remove())
    // Strokes already drawn keep fading — the show moved on from the pen,
    // not from the point being made. A stroke still in the air is committed
    // and left to fade too, but claims no click: Escape is not a press.
  }

  // A mark belongs to the slide it was drawn on: when the show moves (or
  // the deck is swapped underneath), the ink goes with it. Re-dresses the
  // canvas on the way out, because a swapped-in deck arrives bare.
  clear() {
    this._endStroke(true)
    this._reapers.forEach(reaper => clearTimeout(reaper))
    this._reapers.clear()
    this.wrapper.querySelectorAll(".deck-ink").forEach(layer => layer.remove())
    if (this.armed) this._dress()
  }

  destroy() {
    this.stow()
    this.clear()
  }

  // Whether the click now landing is the tail of a stroke. Preventing
  // pointerdown's default (below) suppresses the compatibility mousedown
  // with it, so a stroke leaves no pointer travel for the presenter's own
  // drag guard to measure — the pen has to own up to its gesture, or the
  // stroke would also page the show forward. One-shot: the next press
  // starts the answer over.
  consumePainted() {
    const painted = this.painted
    this.painted = false
    return painted
  }

  _handlePointerDown(event) {
    // Only the primary contact draws: a right-click opens the context menu,
    // and the second finger of a pinch is not a second pen.
    if (!event.isPrimary || event.button !== 0) return

    const deck = this.wrapper.querySelector(".deck")
    if (!deck || !deck.contains(event.target)) return
    // Real UI above the show keeps its pointer: the diagram lightbox, a
    // popover the presenter opened on purpose.
    if (event.target.closest("dialog")) return
    const popover = event.target.closest("[popover]")
    if (popover && popover !== deck && popover.matches(":popover-open")) return

    // This press starts a mark, not a text selection or a link/image drag.
    event.preventDefault()

    this.painted = false
    const rect = deck.getBoundingClientRect()
    this.stroke = {
      deck, rect, pointerId: event.pointerId, path: null, travel: 0,
      points: [{ x: event.clientX - rect.left, y: event.clientY - rect.top }]
    }
  }

  _handlePointerMove(event) {
    const stroke = this.stroke
    if (!stroke || event.pointerId !== stroke.pointerId) return

    const point = { x: event.clientX - stroke.rect.left, y: event.clientY - stroke.rect.top }
    const last = stroke.points[stroke.points.length - 1]
    const step = Math.hypot(point.x - last.x, point.y - last.y)
    if (step < MIN_STEP) return

    stroke.points.push(point)
    stroke.travel += step
    // Nothing is drawn until the gesture proves itself a stroke: a press
    // that goes nowhere is the presenter advancing the show, and a dot
    // flashing under every click would read as a rendering bug.
    if (!stroke.path) {
      if (stroke.travel <= MIN_TRAVEL) return
      stroke.path = this._path(stroke)
    }
    stroke.path.setAttribute("d", pathData(stroke.points))
  }

  _handlePointerEnd(event) {
    if (!this.stroke || event.pointerId !== this.stroke.pointerId) return

    // Only a lifted pointer synthesizes the click the presenter has to
    // swallow, so only a lifted pointer claims one. A cancelled gesture (the
    // browser took the pointer away mid-stroke) produces no click at all —
    // claiming one would leave the flag set, and the presenter's next
    // unrelated click would be eaten instead of advancing the show. The
    // half-drawn mark goes with it: a cancelled stroke was never made.
    if (event.type === "pointercancel") return this._endStroke(true)

    this.painted = !!this.stroke.path
    this._endStroke()
  }

  _endStroke(discard = false) {
    const stroke = this.stroke
    this.stroke = null
    // No path means the press never became a stroke — nothing to fade,
    // and the click it synthesizes belongs to the show.
    if (!stroke?.path) return
    if (discard) return stroke.path.remove()

    // Hand the fade to CSS, and reap the node on a timer regardless:
    // animationend never arrives where animations are turned off, and a
    // stroke that outlives its fade would sit on the slide forever.
    stroke.path.classList.add("deck-ink__stroke--done")
    stroke.path.addEventListener("animationend", () => stroke.path.remove(), { once: true })
    const reaper = setTimeout(() => {
      stroke.path.remove()
      this._reapers.delete(reaper)
    }, STROKE_LIFE_MS + 250)
    this._reapers.add(reaper)
  }

  _path(stroke) {
    const path = document.createElementNS(SVG_NS, "path")
    path.setAttribute("class", "deck-ink__stroke")
    path.setAttribute("stroke-width", round(stroke.rect.width * STROKE_RATIO))
    this._layer(stroke.deck, stroke.rect).appendChild(path)
    return path
  }

  _layer(deck, rect) {
    let layer = deck.querySelector(":scope > .deck-ink")
    if (!layer) {
      layer = document.createElementNS(SVG_NS, "svg")
      layer.setAttribute("class", "deck-ink")
      layer.setAttribute("aria-hidden", "true")
      deck.appendChild(layer)
    }
    // The viewBox is the canvas in CSS pixels, so pointer coordinates map
    // straight through with no scaling math — and a live stroke keeps its
    // place if the window is resized under it.
    layer.setAttribute("viewBox", `0 0 ${round(rect.width)} ${round(rect.height)}`)
    return layer
  }

  // The mode has to be visible: a drag that suddenly paints instead of
  // highlighting is otherwise a mystery.
  _dress() {
    const deck = this.wrapper.querySelector(".deck")
    if (!deck) return

    deck.classList.add("deck--inking")
    if (!deck.querySelector(":scope > .deck-ink-badge")) deck.insertAdjacentHTML("beforeend", BADGE_HTML)
  }
}
