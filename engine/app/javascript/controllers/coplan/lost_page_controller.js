import { Controller } from "@hotwired/stimulus"

const DIRECTIONS = ["up", "right", "down", "left"]
const BITS = [1, 2, 4, 8]
const rotate = (mask) => ((mask << 1) & 15) | (mask >> 3)

export default class extends Controller {
  static targets = ["tile", "status", "moves", "reset"]

  connect() {
    this.resetTarget.disabled = false
    this.reset()
  }

  reset() {
    this.moves = 0
    this.won = false
    this.tileTargets.forEach((tile) => {
      tile.disabled = false
      tile.dataset.mask = tile.dataset.initialMask
      tile.dataset.turns = 0
      tile.querySelector("svg").style.transform = "rotate(0deg)"
    })
    this.update()
  }

  turn(event) {
    if (this.won) return
    const tile = event.currentTarget
    tile.dataset.mask = rotate(Number(tile.dataset.mask))
    tile.dataset.turns = Number(tile.dataset.turns) + 1
    tile.querySelector("svg").style.transform = `rotate(${Number(tile.dataset.turns) * 90}deg)`
    this.moves++
    this.update()
  }

  navigate(event) {
    const direction = ["ArrowUp", "ArrowRight", "ArrowDown", "ArrowLeft"].indexOf(event.key)
    if (direction < 0) return
    event.preventDefault()
    const index = this.tileTargets.indexOf(event.currentTarget)
    const next = this.neighbor(index, direction)
    if (next !== null) this.tileTargets[next].focus()
  }

  neighbor(index, direction) {
    const row = Math.floor(index / 4)
    const col = index % 4
    if ((direction === 0 && row === 0) || (direction === 1 && col === 3) ||
        (direction === 2 && row === 3) || (direction === 3 && col === 0)) return null
    return index + [-4, 1, 4, -1][direction]
  }

  update() {
    const masks = this.tileTargets.map((tile) => Number(tile.dataset.mask))
    const connected = new Set()
    const queue = masks[0] & 8 ? [0] : []
    while (queue.length) {
      const index = queue.shift()
      if (connected.has(index)) continue
      connected.add(index)
      BITS.forEach((bit, direction) => {
        const next = this.neighbor(index, direction)
        if (next !== null && (masks[index] & bit) && (masks[next] & BITS[(direction + 2) % 4])) queue.push(next)
      })
    }
    this.won = connected.has(15) && Boolean(masks[15] & 2)
    this.element.classList.toggle("is-solved", this.won)
    this.tileTargets.forEach((tile, index) => {
      tile.classList.toggle("is-connected", connected.has(index))
      const ends = DIRECTIONS.filter((_, direction) => masks[index] & BITS[direction]).join(" and ")
      tile.setAttribute("aria-label", `Row ${Math.floor(index / 4) + 1}, column ${index % 4 + 1}: ${ends}${connected.has(index) ? ", connected to start" : ""}. Rotate clockwise.`)
      // Keep the focused tile reachable after winning; reset is the next tab stop.
      tile.setAttribute("aria-disabled", String(this.won))
      tile.tabIndex = this.won ? -1 : 0
    })
    this.movesTarget.textContent = `${this.moves} ${this.moves === 1 ? "turn" : "turns"}`
    const message = this.won
      ? "Route found! If only every broken link were this easy."
      : "Connect IN to OUT. The blue line shows how far you’ve made it."
    if (this.statusTarget.textContent !== message) this.statusTarget.textContent = message
  }
}
