import { Controller } from "@hotwired/stimulus"

// Styled replacement for a native file input, attached to the upload form:
// click the zone (or drag files onto it) and the upload starts as soon as
// files are chosen — no separate Upload button.
//
// Uploads go over XHR (fetch has no upload progress) so the zone can show a
// real progress bar, then the server's Turbo Stream response swaps the
// attachments section in place — the page never reloads or scrolls.
export default class extends Controller {
  static targets = ["input", "zone", "label", "progress", "fill"]

  disconnect() {
    // Turbo navigation mid-upload: every plan page has the same
    // #plan-attachments target, so a late response from plan A would
    // happily replace plan B's section. Abort — the upload belongs to a
    // page that no longer exists.
    this.xhr?.abort()
    this.xhr = null
  }

  open() {
    this.inputTarget.click()
  }

  dragOver(event) {
    event.preventDefault()
    this.zoneTarget.classList.add("dropzone--active")
  }

  dragLeave() {
    this.zoneTarget.classList.remove("dropzone--active")
  }

  drop(event) {
    event.preventDefault()
    this.zoneTarget.classList.remove("dropzone--active")
    if (!event.dataTransfer?.files?.length) return
    this.inputTarget.files = event.dataTransfer.files
    this.submit()
  }

  changed() {
    if (this.inputTarget.files.length) this.submit()
  }

  submit() {
    const count = this.inputTarget.files.length
    const noun = count === 1 ? "file" : "files"
    this.originalLabel ??= this.hasLabelTarget ? this.labelTarget.textContent : null
    if (this.hasLabelTarget) this.labelTarget.textContent = `Uploading ${count} ${noun}… 0%`
    this.zoneTarget.classList.add("dropzone--busy")
    this.#setProgress(0)

    const xhr = new XMLHttpRequest()
    xhr.open("POST", this.element.action)
    xhr.setRequestHeader("Accept", "text/vnd.turbo-stream.html, text/html")
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) xhr.setRequestHeader("X-CSRF-Token", token)

    xhr.upload.addEventListener("progress", event => {
      if (!event.lengthComputable) return
      const percent = Math.round((event.loaded / event.total) * 100)
      this.#setProgress(percent)
      if (this.hasLabelTarget) {
        this.labelTarget.textContent = percent < 100
          ? `Uploading ${count} ${noun}… ${percent}%`
          : "Processing…"
      }
    })

    xhr.addEventListener("load", () => {
      this.xhr = null
      const type = xhr.getResponseHeader("Content-Type") || ""
      if (xhr.status < 300 && type.includes("turbo-stream") && window.Turbo) {
        // Replaces #plan-attachments (this form included) and toasts —
        // nothing to reset here, the fresh render is the reset.
        window.Turbo.renderStreamMessage(xhr.responseText)
      } else if (xhr.status < 400 && window.Turbo) {
        // Non-stream success (redirect followed to HTML): fall back to a
        // proper visit of wherever we landed.
        window.Turbo.visit(xhr.responseURL || window.location.href)
      } else {
        this.#fail(`Upload failed (${xhr.status}). Try again.`)
      }
    })

    xhr.addEventListener("error", () => {
      this.xhr = null
      this.#fail("Upload failed — check your connection and try again.")
    })

    this.xhr = xhr
    xhr.send(new FormData(this.element))
  }

  #setProgress(percent) {
    if (!this.hasProgressTarget) return
    this.progressTarget.hidden = false
    if (this.hasFillTarget) this.fillTarget.style.width = `${percent}%`
  }

  #fail(message) {
    this.zoneTarget.classList.remove("dropzone--busy")
    if (this.hasProgressTarget) this.progressTarget.hidden = true
    if (this.hasLabelTarget && this.originalLabel) this.labelTarget.textContent = this.originalLabel
    // Clear the selection so picking the same file again re-fires change.
    this.inputTarget.value = ""

    const container = document.getElementById("coplan-toasts")
    if (!container) return alert(message)
    const toast = document.createElement("div")
    toast.className = "flash flash--alert toasts__toast"
    toast.setAttribute("role", "status")
    toast.dataset.controller = "coplan--toast"
    toast.textContent = message
    container.appendChild(toast)
  }
}
