import { t } from "coplan/ui_messages"
import VoiceController from "controllers/coplan/voice_controller"

// Share the microphone capture, silence detection, and browser fallback with
// push-to-talk. Embedded dictation only inserts into the current draft.
export default class extends VoiceController {
  static targets = ["input", "label", "button", "status"]

  connect() {
    this.mode = this._chooseMode()
    this.listening = false
    this.generation = 0
    if (!this.mode) {
      this.buttonTarget.disabled = true
      this.buttonTarget.title = t("coplan.client.discussions.dictation_unavailable")
      this.labelTarget.textContent = t("coplan.client.discussions.mic_unavailable")
      return
    }
    if (this.mode === "recognize") this._setUpRecognition()
    this.element.dataset.voiceReady = "true"
  }

  disconnect() {
    this.cancel()
    super.disconnect()
  }

  toggle() {
    if (!this.mode || this.processing || (this.capturePending && !this.listening)) return
    if (this.listening) {
      this._stop()
    } else {
      this.generation += 1
      this._start()
    }
  }

  otherStarted(event) {
    if (event.detail.owner !== this.element) this.cancel()
  }

  _start() {
    // Aborted browser captures can still deliver queued callbacks. Each take
    // owns its recognition object so old speech cannot land in a new draft.
    if (this.mode === "recognize") {
      this._setUpRecognition()
      const generation = this.generation
      for (const name of ["onresult", "onend", "onerror"]) {
        const handler = this.recognition[name]
        this.recognition[name] = event => { if (generation === this.generation) handler(event) }
      }
    }
    this.setBusy(true)
    this.labelTarget.textContent = t("coplan.client.discussions.stop")
    this.buttonTarget.setAttribute("aria-pressed", "true")
    try { super._start() } catch { this._reportMiss(t("coplan.client.discussions.microphone_start_failed")) }
  }

  async _startRecording() {
    this.capturePending = true
    const generation = this.generation
    try {
      await super._startRecording()
      const recorder = this.recorder
      if (recorder?.onstop) {
        const onstop = recorder.onstop
        recorder.onstop = () => { if (generation === this.generation) onstop() }
      }
    } catch { this._reportMiss(t("coplan.client.discussions.microphone_start_failed")) }
    finally {
      this.capturePending = false
      this.buttonTarget.disabled = !this.mode || this.processing
    }
  }

  _stopListening() {
    super._stopListening()
    this.buttonTarget.setAttribute("aria-pressed", "false")
    this.labelTarget.textContent = t("coplan.client.discussions.dictate")
  }

  microphoneChanged() {
    this.cancel()
    this._setStatus(t("coplan.client.discussions.input_changed"))
  }

  _onRecognitionError(event) {
    super._onRecognitionError(event)
    this.setBusy(false)
  }

  _onRecognitionEnd() {
    super._onRecognitionEnd()
    if (!this.processing) {
      this.setBusy(false)
      if (!this.recognitionFailed && !this.finalTranscript?.trim()) this._setStatus(t("coplan.client.discussions.no_speech"))
    }
  }

  async _submit({ transcript, audio, durationMs }) {
    const generation = this.generation
    this.processing = true
    this.buttonTarget.disabled = true
    this._setStatus(audio ? t("coplan.client.discussions.transcribing") : t("coplan.client.discussions.adding_to_draft"))
    try {
      if (audio) {
        this.request = new AbortController()
        this.timeout = setTimeout(() => this.request?.abort(), 30000)
        const body = new FormData()
        body.append("audio", audio, `dictation.${this._extensionFor(audio)}`)
        body.append("duration_ms", durationMs)
        body.append("mode", "draft")
        const response = await fetch(this.urlValue, { method: "POST", body, signal: this.request.signal,
          headers: { "Accept": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content } })
        const data = await response.json()
        if (!response.ok) throw new Error(data.error || t("coplan.client.discussions.transcription_failed"))
        transcript = data.transcript
      }
      if (generation !== this.generation || !this.element.isConnected) return
      if (!transcript?.trim()) throw new Error(t("coplan.client.discussions.no_speech"))
      const input = this.inputTarget
      const start = input.selectionStart
      const end = input.selectionEnd
      const prefix = start && !/\s/.test(input.value[start - 1]) ? " " : ""
      const suffix = end < input.value.length && !/\s/.test(input.value[end]) ? " " : ""
      input.setRangeText(prefix + transcript.trim() + suffix, start, end, "end")
      input.dispatchEvent(new Event("input", { bubbles: true }))
      input.focus({ preventScroll: true })
      this._setStatus(t("coplan.client.discussions.added_to_draft"))
    } catch (error) {
      if (generation === this.generation) this._setStatus(error.name === "AbortError" ? t("coplan.client.discussions.dictation_timed_out") : error.message, true)
    } finally {
      if (generation === this.generation) {
        clearTimeout(this.timeout)
        this.processing = false
        this.buttonTarget.disabled = false
        this.setBusy(false)
      }
    }
  }

  _reportMiss(text) {
    this._stopListening()
    this._releaseMic()
    this.setBusy(false)
    this._setStatus(text, true)
  }

  setBusy(busy) {
    this.element.dataset.dictationBusy = String(busy)
    this.element.querySelector('[type="submit"]').disabled = busy
  }

  cancel() {
    this.generation += 1
    this._cancel()
    this._releaseMic()
    this.request?.abort()
    clearTimeout(this.timeout)
    this.processing = false
    this.setBusy(false)
    this.buttonTarget.disabled = !this.mode || this.capturePending
    this._setStatus("")
  }

  closed(event) {
    if (event.target.contains(this.element)) this.cancel()
  }
}
