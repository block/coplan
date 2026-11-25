import { t } from "coplan/ui_messages"
import { Controller } from "@hotwired/stimulus"
import { selectedMicrophone, selectMicrophone, supportsRecognitionTrack, microphoneError } from "coplan/microphone"

export default class extends Controller {
  static targets = ["button", "panel", "input", "status", "refresh"]
  static values = { transcription: Boolean }

  connect() {
    this.canSelect = this.transcriptionValue || supportsRecognitionTrack()
    this.refreshTarget.hidden = !this.canSelect
    if (!this.canSelect) this.statusTarget.textContent = t("coplan.client.discussions.system_microphone_only")
  }

  disconnect() { this.generation = (this.generation || 0) + 1 }

  async toggle() {
    if (this.panelTarget.matches(":popover-open")) return this.panelTarget.hidePopover()
    this.panelTarget.showPopover()
    this.position()
    this.buttonTarget.setAttribute("aria-expanded", "true")
    if (this.canSelect) await this.load()
    else this.loadDefaultInput()
  }

  loadDefaultInput() {
    const selected = selectedMicrophone()
    this.inputTarget.replaceChildren(new Option(t("coplan.client.discussions.system_default"), ""))
    if (selected) this.inputTarget.add(new Option(t("coplan.client.discussions.saved_microphone_unsupported"), selected))
    this.inputTarget.value = selected
    this.statusTarget.textContent = selected
      ? t("coplan.client.discussions.saved_microphone_unusable")
      : t("coplan.client.discussions.system_microphone_only")
    this.position()
  }

  position() {
    if (!this.panelTarget.matches(":popover-open")) return
    const rect = this.buttonTarget.getBoundingClientRect()
    const panel = this.panelTarget.getBoundingClientRect()
    this.panelTarget.style.left = `${Math.max(8, Math.min(rect.left, innerWidth - panel.width - 8))}px`
    this.panelTarget.style.top = `${Math.max(8, rect.top - panel.height - 8)}px`
  }

  toggled(event) {
    if (event.target === this.panelTarget && event.newState === "closed") {
      this.buttonTarget.setAttribute("aria-expanded", "false")
      this.generation = (this.generation || 0) + 1
    }
  }

  async load() {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices()
      if (!this.element.isConnected) return
      const inputs = devices.filter(device => device.kind === "audioinput")
      const selected = selectedMicrophone()
      this.inputTarget.replaceChildren(new Option(t("coplan.client.discussions.system_default"), ""))
      inputs.filter(device => device.deviceId && device.deviceId !== "default").forEach((device, index) => {
        this.inputTarget.add(new Option(device.label || `Microphone ${index + 1}`, device.deviceId))
      })
      if (selected && !inputs.some(device => device.deviceId === selected)) {
        this.inputTarget.add(new Option(t("coplan.client.discussions.selected_microphone_unavailable"), selected))
      }
      this.inputTarget.value = selected
      this.statusTarget.textContent = inputs.some(device => device.label) ? t("coplan.client.discussions.microphone_use") : t("coplan.client.discussions.microphone_permission")
    } catch (error) { this.statusTarget.textContent = microphoneError(error) }
    finally { if (this.element.isConnected) this.position() }
  }

  async refresh() {
    const generation = this.generation = (this.generation || 0) + 1
    this.refreshTarget.disabled = true
    this.statusTarget.textContent = t("coplan.client.discussions.requesting_microphone")
    try {
      // Permission reveals device names. Never record or upload this stream.
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      stream.getTracks().forEach(track => track.stop())
      if (generation === this.generation && this.element.isConnected) await this.load()
    } catch (error) {
      if (generation === this.generation) this.statusTarget.textContent = microphoneError(error)
    } finally {
      if (this.element.isConnected) { this.refreshTarget.disabled = false; this.position() }
    }
  }

  change() {
    selectMicrophone(this.inputTarget.value)
    this.buttonTarget.title = `Microphone: ${this.inputTarget.selectedOptions[0].textContent}`
    this.panelTarget.hidePopover()
    this.buttonTarget.focus({ preventScroll: true })
  }

  sync() {
    if (!this.panelTarget.matches(":popover-open")) return
    if (this.canSelect) this.load()
    else this.loadDefaultInput()
  }

  closed(event) {
    if (event.target.contains(this.element)) this.panelTarget.hidePopover()
  }
}
