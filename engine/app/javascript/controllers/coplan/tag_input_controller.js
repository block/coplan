import { Controller } from "@hotwired/stimulus"

// Chip-style tag editor: tags render as removable pills; typing Enter,
// comma, or picking a datalist suggestion adds one. The hidden field stays
// a comma-separated list — the same format the API and controller accept.
export default class extends Controller {
  static targets = ["chips", "input", "hidden"]

  connect() {
    this.tags = this.hiddenTarget.value.split(",").map((t) => t.trim()).filter(Boolean)
    this.render()
  }

  focusInput(event) {
    if (event.target.closest(".tag-input__remove")) return
    this.inputTarget.focus()
  }

  keydown(event) {
    if (event.key === "Enter" || event.key === ",") {
      event.preventDefault()
      this.add(this.inputTarget.value)
    } else if (event.key === "Backspace" && this.inputTarget.value === "") {
      this.tags.pop()
      this.sync()
    }
  }

  // Fires on blur and on datalist selection — commit whatever was typed.
  commit() {
    this.add(this.inputTarget.value)
  }

  add(raw) {
    const name = raw.replace(/,/g, " ").trim()
    if (!name) return
    if (!this.tags.includes(name)) this.tags.push(name)
    this.inputTarget.value = ""
    this.sync()
  }

  remove(event) {
    event.stopPropagation()
    this.tags = this.tags.filter((t) => t !== event.currentTarget.dataset.tag)
    this.sync()
    this.inputTarget.focus()
  }

  sync() {
    this.hiddenTarget.value = this.tags.join(", ")
    this.render()
  }

  render() {
    this.chipsTarget.querySelectorAll(".tag-input__chip").forEach((el) => el.remove())
    for (const tag of this.tags) {
      const chip = document.createElement("span")
      chip.className = "tag-input__chip"
      chip.append(tag)

      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "tag-input__remove"
      remove.dataset.tag = tag
      remove.dataset.action = "coplan--tag-input#remove"
      remove.setAttribute("aria-label", `Remove tag ${tag}`)
      remove.textContent = "×"
      chip.append(remove)

      this.chipsTarget.insertBefore(chip, this.inputTarget)
    }
  }
}
