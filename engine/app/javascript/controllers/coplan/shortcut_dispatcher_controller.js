import { Controller } from "@hotwired/stimulus"
import { dispatchShortcut } from "coplan/shortcuts"

export default class extends Controller {
  capture(event) { dispatchShortcut(event, { capture: true }) }
  keydown(event) { dispatchShortcut(event) }
}
