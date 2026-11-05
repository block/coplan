import { Controller } from "@hotwired/stimulus"

// Reaction chips under a comment. The server renders one copy for every
// viewer (broadcasts have no current_user), listing who reacted; this
// controller marks the viewer's own reactions as pressed and names them
// "You". Clicks update the chips immediately, then the server's Turbo
// Stream replaces them with the saved state.
//
// Requests for one comment run in order. Every saved response updates the
// server snapshot; pending choices are overlaid when its controller connects
// so intermediate responses do not erase the viewer's latest choice.
const queues = new Map()
const pendingReactions = new Map()
const NAME_LIMIT = 10

function enqueue(key, task) {
  const run = (queues.get(key) || Promise.resolve()).catch(() => {}).then(task)
  queues.set(key, run)
  const isLast = () => queues.get(key) === run
  return run.finally(() => { if (isLast()) queues.delete(key) })
}

function version(element) {
  return Number(element?.dataset.version)
}

// A pending request can settle after another tab has saved a newer choice.
// Only server markup with a newer version can advance the rollback baseline.
function confirmPendingReactions(reactions) {
  for (const state of pendingReactions.values()) {
    if (state.commentId !== reactions.getAttribute("data-coplan--comment-reactions-comment-id-value") || version(reactions) <= state.version) continue
    const chip = reactions.querySelector(`.comment-reaction[data-kind="${CSS.escape(state.kind)}"]`)
    const reactors = JSON.parse(chip?.dataset.reactors || "[]")
    state.confirmed = reactors.some(reactor => reactor.id === state.userId)
    state.version = version(reactions)
  }
}

// Responses and broadcasts from concurrent changes can arrive in any
// order. Skip a replacement of the chips older than the copy on screen.
// Turbo renders a stream a frame after announcing it, by which time
// another may have landed, so the check runs at render time.
document.addEventListener("turbo:before-stream-render", event => {
  const stream = event.target
  const render = event.detail.render
  event.detail.render = async streamElement => {
    const current = document.getElementById(stream.getAttribute("target") || "")
    const incoming = stream.templateElement?.content
    if (["replace", "update"].includes(stream.getAttribute("action")) && current && incoming) {
      for (const reactions of incoming.querySelectorAll(".comment-reactions")) {
        confirmPendingReactions(reactions)
        const saved = document.getElementById(reactions.id)
        if (saved && (saved === current || current.contains(saved)) && version(reactions) < version(saved)) {
          reactions.replaceWith(saved.cloneNode(true))
        }
      }
    }
    await render(streamElement)
  }
})

export default class extends Controller {
  static values = { url: String, commentId: String }
  static targets = ["chip", "add", "picker", "option", "tooltip", "chipTemplate"]

  connect() {
    this.me = document.querySelector("meta[name='coplan-current-user-id']")?.content || ""
    this.addTarget.hidden = !this.me
    confirmPendingReactions(this.element)
    this.refresh()
    for (const state of pendingReactions.values()) {
      if (state.commentId !== this.commentIdValue || state.userId !== this.me) continue
      const pending = state.operations.at(-1)
      if (pending) this.setReaction(state.kind, pending.reacted)
    }
  }

  disconnect() {
    this.hideTooltip()
    this.closePicker()
    this.stopClosingOnMove()
  }

  toggle(event) {
    const chip = event.currentTarget
    this.react(chip.dataset.kind, chip.getAttribute("aria-pressed") !== "true")
    if (chip.isConnected && chip.matches(":hover, :focus-visible")) this.showTooltip({ currentTarget: chip })
  }

  pick(event) {
    const option = event.currentTarget
    this.closePicker()
    this.addTarget.focus({ preventScroll: true })
    this.react(option.dataset.kind, option.getAttribute("aria-pressed") !== "true")
  }

  react(kind, reacted) {
    if (!this.me) return
    const commentId = this.commentIdValue
    const key = JSON.stringify([commentId, kind])
    let state = pendingReactions.get(key)
    if (!state) {
      state = { commentId, kind, userId: this.me, version: version(this.element),
        confirmed: this.chipFor(kind)?.getAttribute("aria-pressed") === "true", operations: [] }
      pendingReactions.set(key, state)
    }
    const operation = { reacted }
    state.operations.push(operation)
    this.revert(commentId, kind, reacted)

    const settle = () => {
      state.operations.splice(state.operations.indexOf(operation), 1)
      this.revert(commentId, kind, state.operations.at(-1)?.reacted ?? state.confirmed)
      if (!state.operations.length) pendingReactions.delete(key)
    }

    const url = this.urlValue
    const body = new FormData()
    body.append("kind", kind)
    body.append("reacted", reacted)
    enqueue(commentId, async () => {
      const response = await fetch(url, {
        method: "PATCH", body,
        headers: { "Accept": "text/vnd.turbo-stream.html", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content }
      }).catch(() => { throw new Error("") })
      if (!response.ok) throw new Error(response.status === 422 ? await response.text() : "")
      if (response.redirected || !response.headers.get("Content-Type")?.includes("text/vnd.turbo-stream.html")) throw new Error("")
      return response.text()
    }).then(result => {
      // Confirm before settling, since Turbo renders asynchronously.
      // A newer broadcast still wins over this response.
      const response = document.createElement("template")
      response.innerHTML = result
      for (const template of response.content.querySelectorAll("turbo-stream > template")) {
        template.content.querySelectorAll(".comment-reactions").forEach(confirmPendingReactions)
      }
      settle()
      window.Turbo.renderStreamMessage(result)
    }).catch(error => {
      settle()
      this.toast(error.message || "Couldn't save your reaction. Please try again.")
    })
  }

  // Applies a reaction change to these chips without waiting for the server.
  setReaction(kind, reacted) {
    let chip = this.chipFor(kind)
    const reactors = chip ? this.reactors(chip).filter(reactor => reactor.id !== this.me) : []
    if (reacted) reactors.push({ id: this.me, name: "" })
    if (!reactors.length) {
      if (chip === this.tooltipChip) this.hideTooltip()
      chip?.remove()
    } else {
      chip ||= this.buildChip(kind)
      chip.dataset.reactors = JSON.stringify(reactors)
      chip.querySelector(".comment-reaction__count").textContent = reactors.length
    }
    this.refresh()
  }

  revert(commentId, kind, reacted) {
    document.querySelectorAll(`[data-coplan--comment-reactions-comment-id-value="${CSS.escape(commentId)}"]`).forEach(element => {
      this.application.getControllerForElementAndIdentifier(element, this.identifier)?.setReaction(kind, reacted)
    })
  }

  refresh() {
    this.chipTargets.forEach(chip => {
      const reactors = this.reactors(chip)
      chip.setAttribute("aria-pressed", reactors.some(reactor => reactor.id === this.me))
      chip.setAttribute("aria-label", this.sentence(reactors, this.optionFor(chip.dataset.kind)?.dataset.label))
    })
    this.optionTargets.forEach(option => {
      option.setAttribute("aria-pressed", this.chipFor(option.dataset.kind)?.getAttribute("aria-pressed") === "true")
    })
  }

  showTooltip(event) {
    const chip = event.currentTarget
    if (!chip.isConnected) return
    this.tooltipChip = chip
    const tooltip = this.tooltipTarget
    // The text lives in an attribute (rendered with CSS) so hovering never
    // changes the thread markup that other controllers observe.
    tooltip.dataset.text = this.sentence(this.reactors(chip), this.optionFor(chip.dataset.kind)?.dataset.emoji)
    try { tooltip.showPopover() } catch {}
    this.place(tooltip, chip, { above: true })
  }

  hideTooltip() {
    this.tooltipChip = null
    if (!this.hasTooltipTarget) return
    try { this.tooltipTarget.hidePopover() } catch {}
  }

  // Light dismiss runs before the click, so remember whether this press
  // started with the picker open; otherwise the click would reopen it.
  notePicker() {
    this.pickerWasOpen = this.pickerTarget.matches(":popover-open")
  }

  openPicker() {
    const wasOpen = this.pickerWasOpen || this.pickerTarget.matches(":popover-open")
    this.pickerWasOpen = false
    if (wasOpen) {
      this.closePicker()
      return
    }
    this.hideTooltip()
    try { this.pickerTarget.showPopover() } catch { return }
    this.place(this.pickerTarget, this.addTarget, { above: false })
    this.closeOnMove()
    this.optionTargets[0]?.focus({ preventScroll: true })
  }

  closePicker() {
    if (!this.hasPickerTarget) return
    try { this.pickerTarget.hidePopover() } catch {}
  }

  pickerToggled(event) {
    const open = event.newState === "open"
    this.addTarget.setAttribute("aria-expanded", open)
    if (!open) this.stopClosingOnMove()
    if (!open && this.pickerTarget.contains(document.activeElement)) this.addTarget.focus({ preventScroll: true })
  }

  // The picker is fixed in place, so any scroll (including one inside a
  // comment window, which doesn't bubble) or resize leaves it behind.
  closeOnMove() {
    this.moved ||= () => this.closePicker()
    window.addEventListener("scroll", this.moved, { capture: true, passive: true })
    window.addEventListener("resize", this.moved)
  }

  stopClosingOnMove() {
    if (!this.moved) return
    window.removeEventListener("scroll", this.moved, { capture: true })
    window.removeEventListener("resize", this.moved)
  }

  buildChip(kind) {
    const option = this.optionFor(kind)
    const chip = this.chipTemplateTarget.content.firstElementChild.cloneNode(true)
    chip.dataset.kind = kind
    chip.querySelector(".comment-reaction__emoji").textContent = option.dataset.emoji
    const order = this.optionTargets.map(target => target.dataset.kind)
    const next = this.chipTargets.find(other => order.indexOf(other.dataset.kind) > order.indexOf(kind))
    this.element.insertBefore(chip, next || this.addTarget)
    return chip
  }

  sentence(reactors, reaction) {
    const names = reactors
      .slice()
      .sort((a, b) => (b.id === this.me) - (a.id === this.me))
      .map(reactor => reactor.id === this.me ? "You" : reactor.name)
    const shown = names.slice(0, NAME_LIMIT).join(", ")
    const others = names.length - NAME_LIMIT
    const who = others > 0 ? `${shown} and ${others} ${others === 1 ? "other" : "others"}` : shown
    return `${who} reacted with ${reaction}`
  }

  place(popover, anchor, { above }) {
    const gap = 6
    const margin = 8
    const target = anchor.getBoundingClientRect()
    const box = popover.getBoundingClientRect()
    const fitsAbove = target.top - box.height - gap >= margin
    const fitsBelow = target.bottom + box.height + gap <= window.innerHeight - margin
    const top = (above ? fitsAbove || !fitsBelow : !fitsBelow && fitsAbove)
      ? target.top - box.height - gap
      : target.bottom + gap
    const left = Math.min(Math.max(margin, target.left + target.width / 2 - box.width / 2), window.innerWidth - box.width - margin)
    popover.style.top = `${Math.max(margin, top)}px`
    popover.style.left = `${Math.max(margin, left)}px`
  }

  chipFor(kind) {
    return this.chipTargets.find(chip => chip.dataset.kind === kind)
  }

  optionFor(kind) {
    return this.optionTargets.find(option => option.dataset.kind === kind)
  }

  reactors(chip) {
    try { return JSON.parse(chip.dataset.reactors || "[]") } catch { return [] }
  }

  toast(message) {
    const container = document.getElementById("coplan-toasts")
    if (!container) return
    const toast = document.createElement("div")
    toast.className = "flash flash--alert toasts__toast"
    toast.setAttribute("role", "status")
    toast.dataset.controller = "coplan--toast"
    toast.textContent = message
    container.appendChild(toast)
  }
}
