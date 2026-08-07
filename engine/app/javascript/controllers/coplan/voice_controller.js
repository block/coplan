import { Controller } from "@hotwired/stimulus"

/*
 * coplan--voice
 *
 * Push-to-talk feedback for the plan's agent. Hold the mic button (or tap
 * to toggle), say "this section is way too formal", and the transcript is
 * posted as a comment — which wakes the plan's agent through the normal
 * event inbox. The agent's session pill flips to active, and this
 * controller speaks a short acknowledgment ("Got it.") the moment that
 * happens, then a wrap-up cue when the session completes, so the loop is
 * ear-and-eyes: you hear the ack, you watch the diff flashes land.
 *
 * This is the zero-install voice tier: browser-native SpeechRecognition
 * (on-device in Chrome 139+) and speechSynthesis. The higher-fidelity
 * OSS sidecar (Pipecat + local Whisper + Kokoro over WebRTC) plugs into
 * the same comment-driven loop — see voice/README.md — so this controller
 * is also its fallback.
 */
export default class extends Controller {
  static targets = ["button", "status"]
  static values = { url: String }

  connect() {
    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!Recognition) {
      this.element.style.display = "none"
      return
    }

    this.recognition = new Recognition()
    this.recognition.continuous = false
    this.recognition.interimResults = true
    this.recognition.lang = document.documentElement.lang || "en-US"
    this.recognition.onresult = (e) => this._onResult(e)
    this.recognition.onend = () => this._onEnd()
    this.recognition.onerror = (e) => this._setStatus(e.error === "no-speech" ? "Didn't catch that" : "Mic error", true)

    this.listening = false
    this.finalTranscript = ""
    this._watchAgentPill()
  }

  disconnect() {
    this.recognition?.abort()
    this.pillObserver?.disconnect()
  }

  toggle() {
    this.listening ? this.recognition.stop() : this._start()
  }

  _start() {
    this.finalTranscript = ""
    this.awaitingAck = false
    this.listening = true
    this.buttonTarget.classList.add("voice-btn--listening")
    this._setStatus("Listening…")
    this.recognition.start()
  }

  _onResult(event) {
    let interim = ""
    for (const result of event.results) {
      if (result.isFinal) this.finalTranscript += result[0].transcript
      else interim += result[0].transcript
    }
    this._setStatus(`“${(this.finalTranscript + interim).trim().slice(-80)}”`)
  }

  _onEnd() {
    this.listening = false
    this.buttonTarget.classList.remove("voice-btn--listening")
    const text = this.finalTranscript.trim()
    if (text.length === 0) return

    this._post(text)
  }

  async _post(text) {
    this._setStatus("Sending…")
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const body = new FormData()
    body.append("comment_thread[body_markdown]", `🎙️ ${text}`)

    const response = await fetch(this.urlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": token, "Accept": "text/vnd.turbo-stream.html, text/html" },
      body
    })

    if (response.ok) {
      this.awaitingAck = true
      this._setStatus("Sent — waiting for the agent…")
      // If no agent picks it up shortly, stop promising.
      setTimeout(() => {
        if (this.awaitingAck) this._setStatus("")
        this.awaitingAck = false
      }, 20000)
    } else {
      this._setStatus("Couldn't send", true)
    }
  }

  // The agent session pill is broadcast-replaced whole; watch it and turn
  // its state changes into speech. active → "Got it." (once per request),
  // pill gone/complete → "Done — take a look."
  _watchAgentPill() {
    const pillHost = document.getElementById("plan-agent-sessions")?.parentNode
    if (!pillHost) return

    this.pillObserver = new MutationObserver(() => {
      const active = document.querySelector(".agent-pill--active, .agent-pill--pending")
      if (this.awaitingAck && active) {
        this.awaitingAck = false
        this.spokeAck = true
        this._speak("Got it.")
        this._setStatus("Agent is on it…")
      } else if (this.spokeAck && !active) {
        this.spokeAck = false
        this._speak("Done — take a look.")
        this._setStatus("")
      }
    })
    this.pillObserver.observe(pillHost, { childList: true, subtree: true })
  }

  _speak(text) {
    if (!window.speechSynthesis) return
    const utterance = new SpeechSynthesisUtterance(text)
    utterance.rate = 1.1
    window.speechSynthesis.speak(utterance)
  }

  _setStatus(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("voice-status--error", isError)
  }
}
