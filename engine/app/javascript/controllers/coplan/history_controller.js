import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "frame", "status", "retry"]
  static values = { from: Number, to: Number }

  connect() {
    this.syncSelection()
    // A Turbo snapshot can capture an in-flight comparison before disconnect
    // aborts it. Resume that selection when returning to the cached page.
    if (this.frameTarget.hidden && this.fromValue) this.load()
  }

  disconnect() {
    this.request?.abort()
  }

  // A streamed revision is available for selection without changing the
  // range the reader is already reviewing.
  itemTargetConnected() {
    this.syncSelection()
  }

  select(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    this.fromValue = this.toValue = Number(event.currentTarget.dataset.revision)
    this.load()
  }

  toggle(event) {
    const revision = Number(event.currentTarget.value)
    if (event.currentTarget.checked) {
      this.fromValue = this.fromValue ? Math.min(this.fromValue, revision) : revision
      this.toValue = Math.max(this.toValue, revision)
    } else if (this.fromValue === this.toValue) {
      this.fromValue = this.toValue = 0
    } else if (revision === this.toValue) {
      this.toValue--
    } else {
      // Removing an interior revision cannot leave a hole: keep the newer
      // end of the range. Removing the oldest just shrinks that edge.
      this.fromValue = revision + 1
    }
    this.load()
  }

  clear() {
    this.fromValue = this.toValue = 0
    this.load()
  }

  syncSelection() {
    this.itemTargets.forEach(item => {
      const revision = Number(item.dataset.revision)
      const selected = revision >= this.fromValue && revision <= this.toValue
      item.classList.toggle("history-split__item--active", selected)
      item.querySelector("input").checked = selected
    })
  }

  async load() {
    this.request?.abort()
    this.syncSelection()
    this.retryTarget.hidden = true
    this.frameTarget.hidden = true
    this.frameTarget.removeAttribute("aria-busy")

    const location = new URL(window.location.href)
    if (this.fromValue) {
      location.searchParams.set("from", this.fromValue)
      location.searchParams.set("to", this.toValue)
    } else {
      location.searchParams.delete("from")
      location.searchParams.delete("to")
    }
    window.history.replaceState(window.history.state, "", location)

    if (!this.fromValue) {
      this.statusTarget.textContent = "Select a revision to see its changes, then check another to extend the range."
      return
    }

    const selected = this.itemTargets.find(item => Number(item.dataset.revision) === this.toValue)
    const url = new URL(selected.querySelector("a").href)
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
      this.statusTarget.textContent = "Couldn't load this comparison. Try again."
      this.retryTarget.hidden = false
    } finally {
      if (this.request === request) this.frameTarget.removeAttribute("aria-busy")
    }
  }
}
