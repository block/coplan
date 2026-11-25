import { Controller } from "@hotwired/stimulus"
import { commandFor, registerShortcuts } from "coplan/shortcuts"

export default class extends Controller {
  static targets = ["item", "base", "head", "snapshot", "frame", "status", "retry"]
  static values = { from: Number, to: Number, anchor: Number, cursor: Number }

  connect() {
    this.anchorValue ||= this.fromValue
    this.cursorValue ||= this.toValue
    this.releaseShortcuts = registerShortcuts(this, "history", event => this.navigate(event))
    this.syncSelection()
    // A Turbo snapshot can capture an in-flight comparison before disconnect
    // aborts it. Resume that selection when returning to the cached page.
    if (this.frameTarget.hasAttribute("aria-busy")) this.load()
  }

  disconnect() {
    this.releaseShortcuts?.()
    this.releaseShortcuts = null
    this.request?.abort()
  }

  // A streamed revision is available for selection without changing the
  // range the reader is already reviewing.
  itemTargetConnected() {
    if (this.releaseShortcuts) this.syncSelection()
  }

  select(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return
    event.preventDefault()
    this.selectRevision(Number(event.currentTarget.dataset.revision), event.shiftKey)
  }

  selectRevision(revision, extend) {
    if (!extend) this.anchorValue = revision
    this.cursorValue = revision
    this.fromValue = Math.min(this.anchorValue, revision)
    this.toValue = Math.max(this.anchorValue, revision)
    this.load()
  }

  navigate(event) {
    const focusedRow = event.target.closest(".history-split__entry")
    if (!focusedRow && event.target.closest("a, button, summary, .history-split__diff")) return

    const command = commandFor("history", event)
    const cursor = Number(focusedRow?.dataset.revision) || this.cursorValue
    const revisions = this.revisions
    const next = revisions[revisions.indexOf(cursor) + (command.endsWith("older") ? 1 : -1)]
    event.preventDefault()
    if (!next) return

    this.selectRevision(next, command.startsWith("extend-"))
    const link = this.linkFor(next)
    link.focus({ preventScroll: true })
    link.scrollIntoView({ block: "nearest", inline: "nearest" })
  }

  changeBase(event) {
    // Existing URLs store the first included edit. The picker shows the
    // snapshot immediately before that edit as the comparison's start.
    this.fromValue = Number(event.currentTarget.value) + 1
    this.selectEndpoints()
  }

  changeHead(event) {
    this.toValue = Number(event.currentTarget.value)
    this.selectEndpoints()
  }

  selectEndpoints() {
    this.anchorValue = this.fromValue
    this.cursorValue = this.toValue
    this.load()
  }

  get revisions() {
    return this.itemTargets.map(item => Number(item.dataset.revision)).sort((a, b) => b - a)
  }

  linkFor(revision) {
    return this.itemTargets.find(item => Number(item.dataset.revision) === revision).querySelector("a")
  }

  setOptions(select, revisions, selected) {
    select.replaceChildren(...revisions.map(revision =>
      new Option(revision === 0 ? "Empty document" : `v${revision}`, revision, revision === selected, revision === selected)
    ))
  }

  syncSelection() {
    const revisions = this.revisions
    this.setOptions(this.baseTarget, [...revisions.filter(revision => revision < this.toValue), 0], this.fromValue - 1)
    this.setOptions(this.headTarget, revisions.filter(revision => revision >= this.fromValue), this.toValue)

    const snapshot = new URL(this.linkFor(this.toValue).href)
    snapshot.searchParams.set("from", this.fromValue)
    this.snapshotTarget.href = snapshot.href
    this.snapshotTarget.textContent = `View v${this.toValue}`

    this.itemTargets.forEach(item => {
      const revision = Number(item.dataset.revision)
      const selected = revision >= this.fromValue && revision <= this.toValue
      item.classList.toggle("history-split__item--active", selected)
      const link = item.querySelector("a")
      if (revision === this.toValue) link.setAttribute("aria-current", "true")
      else link.removeAttribute("aria-current")
    })
  }

  replaceRangeLocation() {
    const location = new URL(window.location.href)
    location.searchParams.set("from", this.fromValue)
    location.searchParams.set("to", this.toValue)

    const navigator = window.Turbo?.navigator
    if (navigator?.history?.replace && navigator.view) {
      // The comparison changes in place, so Turbo never renders this URL
      // itself. Cache the current page under that URL for browser Back.
      navigator.history.replace(location, navigator.history.restorationIdentifier)
      navigator.view.lastRenderedLocation = location
    } else {
      window.history.replaceState(window.history.state, "", location)
    }
  }

  async load() {
    this.request?.abort()
    this.syncSelection()
    this.retryTarget.hidden = true
    this.replaceRangeLocation()

    const url = new URL(this.linkFor(this.toValue).dataset.diffUrl, window.location.origin)
    url.searchParams.set("from", this.fromValue)
    const request = this.request = new AbortController()
    this.statusTarget.textContent = "Loading comparison…"
    this.frameTarget.setAttribute("aria-busy", "true")

    try {
      const response = await fetch(url, { signal: request.signal, credentials: "same-origin",
        headers: { Accept: "text/html", "Turbo-Frame": "version-diff" } })
      if (!response.ok) throw new Error("comparison failed")
      const document = new DOMParser().parseFromString(await response.text(), "text/html")
      const frame = document.querySelector("turbo-frame#version-diff")
      if (!frame) throw new Error("comparison missing")
      if (request.signal.aborted) return

      this.frameTarget.innerHTML = frame.innerHTML
      this.frameTarget.hidden = false
      this.statusTarget.textContent = ""
    } catch (error) {
      if (request.signal.aborted) return
      this.frameTarget.hidden = true
      this.statusTarget.textContent = "Couldn't load this comparison. Try again."
      this.retryTarget.hidden = false
    } finally {
      if (this.request === request) this.frameTarget.removeAttribute("aria-busy")
    }
  }
}
