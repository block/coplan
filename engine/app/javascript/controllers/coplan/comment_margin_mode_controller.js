import { Controller } from "@hotwired/stimulus"
import { commentMarginMode, setCommentMarginMode } from "coplan/comment_margin"

// The Markers / Cards switch for the discussion margin. The margin controller
// reports how many discussions it shows and when the window is too narrow
// for cards, so the switch appears only while there is something to switch
// and can explain why Cards is showing markers.
export default class extends Controller {
  static targets = ["option"]

  connect() {
    this.render(commentMarginMode())
  }

  choose(event) {
    const mode = event.currentTarget.dataset.mode
    setCommentMarginMode(mode)
    this.render(mode)
  }

  layoutChanged({ detail }) {
    this.element.hidden = detail.count === 0
    this.element.toggleAttribute("data-fallback", detail.fallback)
    const cards = this.optionTargets.find(option => option.dataset.mode === "cards")
    cards.title = detail.fallback ? cards.dataset.fallbackTitle : cards.dataset.defaultTitle
  }

  render(mode) {
    for (const option of this.optionTargets) option.setAttribute("aria-pressed", String(option.dataset.mode === mode))
  }
}
