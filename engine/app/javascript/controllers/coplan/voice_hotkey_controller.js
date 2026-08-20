import { Controller } from "@hotwired/stimulus"

/*
 * coplan--voice-hotkey
 *
 * Saves the push-to-talk key as soon as it's picked — settings here don't
 * have a save button. Nothing on this page reads the key, so there is no
 * local state to update; the plan page picks it up on its next load.
 */
export default class extends Controller {
  static targets = ["macNote"]
  static values = { url: String }

  select(event) {
    const hotkey = event.target.value

    if (this.hasMacNoteTarget) this.macNoteTarget.hidden = hotkey !== "ctrl_space"

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": csrfToken
      },
      body: `voice_hotkey=${hotkey}`
    })
  }
}
