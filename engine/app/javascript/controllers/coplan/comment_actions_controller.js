import { Controller } from "@hotwired/stimulus"

// Reveals per-viewer actions (currently just Delete) when this comment
// belongs to the signed-in user. Broadcasts render once for all viewers
// with no current_user, so the server emits the affordance for every
// human comment and lets each browser decide whether to show it. The
// server still enforces auth on submit — this is UX, not security.
export default class extends Controller {
  static values = { authorId: String, authorType: String }
  static targets = ["delete"]

  connect() {
    const me = document.querySelector("meta[name='coplan-current-user-id']")?.content
    const isMine = this.authorTypeValue === "human" &&
                   !!me &&
                   this.authorIdValue === me
    if (isMine && this.hasDeleteTarget) {
      this.deleteTarget.hidden = false
    }
  }
}
