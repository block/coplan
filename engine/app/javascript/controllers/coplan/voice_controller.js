import { Controller } from "@hotwired/stimulus"

/*
 * coplan--voice
 *
 * Push-to-talk commenting. Hold the mic button (or tap to toggle), say
 * "this section is way too formal", and the transcript is posted as a
 * comment pinned to the section you were looking at.
 *
 * It promises nothing about agents. If one happens to be attached the
 * comment wakes it through the normal event inbox, its pill flips to
 * active, and this controller speaks a short acknowledgment ("Got it.")
 * at that moment — so the loop is ear-and-eyes: you hear the ack, you
 * watch the diff flashes land. With nobody attached it's simply a
 * dictated comment, which stays in the durable inbox for whichever agent
 * attaches next.
 *
 * This is the zero-install voice tier: browser-native SpeechRecognition
 * (on-device in Chrome 139+) and speechSynthesis. The higher-fidelity
 * OSS sidecar (Pipecat + local Whisper + Kokoro over WebRTC) plugs into
 * the same comment-driven loop — see voice/README.md — so this controller
 * is also its fallback.
 */
export default class extends Controller {
  static targets = ["button", "status"]
  static values = { url: String, anchorUrl: String }

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

    // Pin the note to what you were talking about. The section on screen
    // is the floor; if the AI can pick out the actual sentence from what
    // was visible, the highlight lands there instead.
    const anchor = (await this._precisePin(text)) || this._viewportAnchor()
    if (anchor) {
      body.append("comment_thread[anchor_text]", anchor.text)
      body.append("comment_thread[anchor_occurrence]", anchor.occurrence)
    }

    const response = await fetch(this.urlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": token, "Accept": "text/vnd.turbo-stream.html, text/html" },
      body
    })

    if (!response.ok) {
      this._setStatus("Couldn't send", true)
      return
    }

    // State what happened, and nothing more. Whether an agent picks this
    // up isn't ours to promise — if one does, its pill says so, and the
    // observer below speaks the acknowledgment.
    this.awaitingAck = true
    this._setStatus(anchor ? `Comment added to “${this._truncate(anchor.text)}”` : "Comment added")
    setTimeout(() => {
      this.awaitingAck = false
      this._setStatus("")
    }, 12000)
  }

  // Ask the server which words the remark was about, given only what was
  // on screen. Strictly an upgrade over the heading anchor: it is time-
  // boxed, and any failure — no AI configured, slow model, a paraphrase
  // that doesn't appear in the text — just leaves the fallback in place.
  async _precisePin(transcript) {
    const visible = this._visibleText()
    if (!visible) return null

    this._setStatus("Finding the spot…")
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 4000)

    try {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(this.anchorUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token, Accept: "application/json" },
        body: JSON.stringify({ transcript, excerpt: visible }),
        signal: controller.signal
      })
      if (!response.ok) return null

      const { anchor_text: anchorText } = await response.json()
      if (!anchorText) return null

      // The span has to exist in the rendered document to be highlighted,
      // and we need to know which copy of it we mean.
      const content = document.getElementById("plan-content-body")
      const rendered = content?.textContent || ""
      if (!rendered.includes(anchorText)) return null

      return { text: anchorText, occurrence: this._occurrenceOfNearViewport(content, anchorText) }
    } catch {
      return null
    } finally {
      clearTimeout(timer)
    }
  }

  // The text currently on screen, which is both what the remark was about
  // and the only part of the document we send anywhere.
  _visibleText() {
    const content = document.getElementById("plan-content-body")
    if (!content) return null

    const blocks = Array.from(content.querySelectorAll("h1, h2, h3, h4, h5, h6, p, li, blockquote, pre, td"))
    const visible = blocks.filter((el) => {
      const rect = el.getBoundingClientRect()
      return rect.bottom > 0 && rect.top < window.innerHeight
    })
    const text = (visible.length > 0 ? visible : blocks.slice(0, 20))
      .map((el) => el.textContent.trim())
      .filter(Boolean)
      .join("\n")

    return text.length > 0 ? text : null
  }

  // Which copy of the span to highlight: the first one at or after the
  // top of the viewport. Picking the wrong copy highlights text the
  // person was never looking at, which is worse than not pinning at all.
  _occurrenceOfNearViewport(content, text) {
    const firstVisible = Array.from(content.querySelectorAll("h1, h2, h3, h4, h5, h6, p, li, blockquote, pre, td"))
      .find((el) => el.getBoundingClientRect().bottom > 0)
    if (!firstVisible) return 0

    const range = document.createRange()
    range.setStart(content, 0)
    range.setEndBefore(firstVisible)
    return this._countOccurrences(range.toString(), text)
  }

  // The heading of the section currently in view. Uses the last heading
  // above the reading line, so scrolling mid-section still pins to that
  // section rather than to the one coming up.
  _viewportAnchor() {
    const content = document.getElementById("plan-content-body")
    if (!content) return null

    const headings = Array.from(content.querySelectorAll("h1, h2, h3, h4, h5, h6"))
    if (headings.length === 0) return null

    const readingLine = window.innerHeight * 0.4
    let chosen = null
    for (const heading of headings) {
      if (heading.getBoundingClientRect().top <= readingLine) chosen = heading
      else break
    }
    // Above the first heading: pin to whatever is coming into view.
    chosen ||= headings.find((h) => h.getBoundingClientRect().bottom > 0) || headings[0]

    const text = chosen.textContent.trim()
    if (!text) return null

    return { text, occurrence: this._occurrenceBefore(content, chosen, text) }
  }

  // Which copy of this text it is — headings repeat ("Rollout" under two
  // sections), and the server resolves an anchor by text plus index.
  _occurrenceBefore(content, element, text) {
    const range = document.createRange()
    range.setStart(content, 0)
    range.setEndBefore(element)
    return this._countOccurrences(range.toString(), text)
  }

  // Occurrence is 1-based server-side (resolve_anchor_position treats
  // anything below 1 as "don't resolve"), so this counts the copies that
  // come before the target and numbers the target itself.
  _countOccurrences(prefix, needle) {
    let count = 0
    let index = prefix.indexOf(needle)
    while (index !== -1) {
      count += 1
      index = prefix.indexOf(needle, index + needle.length)
    }
    return count + 1
  }

  _truncate(text, max = 40) {
    return text.length > max ? `${text.slice(0, max)}…` : text
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
        this._setStatus("Agent picked it up…")
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
