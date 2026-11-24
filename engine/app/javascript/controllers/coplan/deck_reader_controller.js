import { t } from "coplan/ui_messages"
import { Controller } from "@hotwired/stimulus"

// One slide is visible while reading each embedded deck. The presenter uses
// the same current slide, so entering and leaving the show keeps your place.
export default class extends Controller {
  static targets = ["count", "previous", "next"]

  connect() {
    this.slides = Array.from(this.element.querySelectorAll(":scope > .deck > .deck-slide"))
    this.show(Number(this.element.dataset.currentSlide || 1) - 1)
    this._onHashChange = () => this.revealFragment()
    window.addEventListener("hashchange", this._onHashChange)
    requestAnimationFrame(this._onHashChange)
  }

  disconnect() { window.removeEventListener("hashchange", this._onHashChange) }

  previous() { this.show(this.index - 1) }
  next() { this.show(this.index + 1) }

  keydown(event) {
    if (event.target.closest("input, textarea, select, [contenteditable='true']")) return
    if (event.key === "ArrowLeft") this.previous()
    else if (event.key === "ArrowRight") this.next()
    else return
    event.preventDefault()
  }

  focus(event) {
    if (event.target.closest("a, button, input, textarea, select")) return
    this.element.focus({ preventScroll: true })
  }

  synced(event) { this.show(event.detail.index) }

  reveal(event) { this.show(Number(event.detail.slide) - 1) }

  revealFragment() {
    if (!window.location.hash || window.location.hash.startsWith("#present-")) return
    let id
    try { id = decodeURIComponent(window.location.hash.slice(1)) } catch { return }
    const target = document.getElementById(id)
    const slide = target?.closest(".deck-slide")
    if (slide && this.element.contains(slide)) {
      this.show(Number(slide.dataset.slide) - 1)
      requestAnimationFrame(() => target.scrollIntoView({ block: "start" }))
    }
  }

  show(index) {
    if (!this.slides.length) return
    this.index = Math.max(0, Math.min(index, this.slides.length - 1))
    this.element.dataset.currentSlide = String(this.index + 1)
    this.slides.forEach((slide, i) => slide.classList.toggle("deck-slide--current", i === this.index))
    this.countTarget.dataset.count = `${this.index + 1} / ${this.slides.length}`
    this.countTarget.setAttribute("aria-label", t("coplan.client.reader.slide_count", { position: this.index + 1, total: this.slides.length }))
    this.previousTarget.disabled = this.index === 0
    this.nextTarget.disabled = this.index === this.slides.length - 1
    this.element.dispatchEvent(new CustomEvent("coplan:deck-slide-changed", { bubbles: true }))
  }
}
