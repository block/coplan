import { Controller } from "@hotwired/stimulus"

/*
 * coplan--voice-hotkey
 *
 * Saves the push-to-talk key as soon as it's picked — settings here don't
 * have a save button. Nothing on this page reads the key, so there is no
 * local state to update; the plan page picks it up on its next load.
 *
 * The click is the feedback: the segment lights up straight away and no
 * spinner narrates a round trip that normally takes a few milliseconds.
 * What that owes the reader is honesty when it doesn't land — a settings
 * page showing a preference the server never took is a lie that only
 * comes out on the next visit, when the key silently isn't what it says.
 * So a failure puts the old choice back and says so.
 */
export default class extends Controller {
  static targets = ["macNote", "error"]
  static values = { url: String }

  connect() {
    this.saved = this.element.querySelector("input[name='voice_hotkey']:checked")?.value
  }

  async select(event) {
    const hotkey = event.target.value
    const previous = this.saved

    this._reflect(hotkey)
    this._setError("")

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    let response = null
    try {
      response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": csrfToken
        },
        body: `voice_hotkey=${encodeURIComponent(hotkey)}`
      })
    } catch {
      // Offline or the request never landed — same outcome as a refusal.
    }

    if (response?.ok) {
      this.saved = hotkey
      return
    }

    // Put the page back to what the server actually has, so what's lit is
    // always the key that will work.
    if (previous) {
      const restored = this.element.querySelector(`input[name='voice_hotkey'][value='${previous}']`)
      if (restored) restored.checked = true
      this._reflect(previous)
    }
    this._setError("Couldn't save that — try again.")
  }

  // Bits of the row that follow the choice rather than the server: the
  // macOS caveat only applies to Ctrl+Space.
  _reflect(hotkey) {
    if (this.hasMacNoteTarget) this.macNoteTarget.hidden = hotkey !== "ctrl_space"
  }

  _setError(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message
    this.errorTarget.hidden = message === ""
  }
}
