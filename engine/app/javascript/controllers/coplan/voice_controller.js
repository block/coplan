import { Controller } from "@hotwired/stimulus"

/*
 * coplan--voice
 *
 * Push-to-talk commenting. Hold Shift (or tap the mic), say "this section
 * is way too formal", and what you said is posted as a comment pinned to
 * the passage you were looking at.
 *
 * Two ways to capture, and which one is in play matters:
 *
 *   record    MediaRecorder captures audio and the server transcribes it.
 *             Works in every browser with a microphone, and the
 *             transcription is far better — it gets a hint of what was on
 *             screen, so jargon, product names and figures come through
 *             instead of being guessed at phonetically. Costs a round
 *             trip and gives no live captions.
 *   recognize The browser's own SpeechRecognition. Instant and free, with
 *             interim text as you speak, but Chrome-only in practice and
 *             noticeably worse at anything domain-specific.
 *
 * Recording wins when the server can transcribe, because accuracy is the
 * whole ballgame: a comment that says something you didn't is worse than
 * no comment. Recognition is the fallback, and with neither the control
 * hides itself.
 *
 * It promises nothing about agents. If one happens to be attached the
 * comment wakes it through the normal event inbox, its pill flips to
 * active, and this controller speaks a short acknowledgment ("Got it.")
 * at that moment. With nobody attached it's simply a dictated comment,
 * which stays in the durable inbox for whichever agent attaches next.
 */
export default class extends Controller {
  static targets = ["button", "status"]
  static values = { url: String, dictationUrl: String, transcription: Boolean }

  connect() {
    this.mode = this._chooseMode()
    if (!this.mode) {
      this.element.style.display = "none"
      return
    }

    if (this.mode === "recognize") this._setUpRecognition()

    this.listening = false
    this._watchAgentPill()
    this._enablePushToTalk()
  }

  disconnect() {
    this._releaseMic()
    this.recognition?.abort()
    this.pillObserver?.disconnect()
    this._disablePushToTalk()
    clearInterval(this.tickTimer)
  }

  _chooseMode() {
    const canRecord = !!(navigator.mediaDevices?.getUserMedia && window.MediaRecorder)
    if (this.transcriptionValue && canRecord) return "record"
    if (window.SpeechRecognition || window.webkitSpeechRecognition) return "recognize"
    return null
  }

  _setUpRecognition() {
    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition
    this.recognition = new Recognition()
    this.recognition.continuous = false
    this.recognition.interimResults = true
    this.recognition.lang = document.documentElement.lang || "en-US"
    this.recognition.onresult = (e) => this._onResult(e)
    this.recognition.onend = () => this._onRecognitionEnd()
    this.recognition.onerror = (e) =>
      this._setStatus(e.error === "no-speech" ? "Didn't catch that" : "Mic error", true)
  }

  // ── The gesture ────────────────────────────────────────────────────

  toggle() {
    this.listening ? this._stop() : this._start()
  }

  // Hold Shift to talk, release to send.
  //
  // Shift is also held while typing capitals and extending a selection,
  // so a bare press isn't enough of a signal. Three guards keep it from
  // firing by accident: it must be Shift alone with no other key down, it
  // must be held past a short delay (capitals are a tap), and any other
  // keystroke or a text selection cancels without posting.
  _enablePushToTalk() {
    this.HOLD_DELAY = 350

    this._onKeyDown = (event) => {
      if (event.key !== "Shift") {
        // Shift+something is a shortcut or a capital letter, not talking.
        if (this.pushToTalk) this._cancel()
        return
      }
      if (event.repeat || this.pushToTalk || this.listening) return
      if (this._isTyping() || event.metaKey || event.ctrlKey || event.altKey) return

      this.holdTimer = setTimeout(() => {
        // Extending a selection with Shift+arrow or Shift+click also
        // holds Shift; if text got selected, that's what was happening.
        if (!window.getSelection()?.isCollapsed) return
        this.pushToTalk = true
        this._start()
      }, this.HOLD_DELAY)
    }

    this._onKeyUp = (event) => {
      if (event.key !== "Shift") return
      clearTimeout(this.holdTimer)
      if (!this.pushToTalk) return

      this.pushToTalk = false
      this._stop()
    }

    // Losing the window means we never see the keyup — don't leave the
    // mic open, and don't post something half-said.
    this._onInterrupt = () => {
      if (this.pushToTalk) this._cancel()
    }

    document.addEventListener("keydown", this._onKeyDown)
    document.addEventListener("keyup", this._onKeyUp)
    window.addEventListener("blur", this._onInterrupt)
  }

  _disablePushToTalk() {
    clearTimeout(this.holdTimer)
    document.removeEventListener("keydown", this._onKeyDown)
    document.removeEventListener("keyup", this._onKeyUp)
    window.removeEventListener("blur", this._onInterrupt)
  }

  _isTyping() {
    const el = document.activeElement
    if (!el) return false
    return el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName)
  }

  // ── Capture ────────────────────────────────────────────────────────

  _start() {
    // What they were looking at when they started talking, not wherever
    // the page has drifted to by the time they stop.
    this.excerpt = this._visibleText()
    this.finalTranscript = ""
    this.awaitingAck = false
    this.discarded = false
    this.listening = true
    this.buttonTarget.classList.add("voice-btn--listening")
    this._startTicking()

    if (this.mode === "record") this._startRecording()
    else this.recognition.start()
  }

  _stop() {
    if (!this.listening) return

    if (this.mode === "record") this.recorder?.stop() // → onstop posts
    else this.recognition?.stop() // → onend posts
  }

  // Discards whatever was captured rather than posting it.
  _cancel() {
    clearTimeout(this.holdTimer)
    this.pushToTalk = false
    if (!this.listening) return

    this.discarded = true
    if (this.mode === "record") this.recorder?.stop()
    else this.recognition?.abort()

    this._stopListening()
    this._setStatus("")
  }

  _stopListening() {
    this.listening = false
    this.buttonTarget.classList.remove("voice-btn--listening")
    clearInterval(this.tickTimer)
  }

  // No live captions in record mode, so the elapsed count is the whole of
  // the "yes, it can hear you" signal.
  _startTicking() {
    if (this.mode !== "record") {
      this._setStatus("Listening…")
      return
    }

    let seconds = 0
    this._setStatus("Listening…")
    clearInterval(this.tickTimer)
    this.tickTimer = setInterval(() => {
      seconds += 1
      this._setStatus(`Listening… ${seconds}s`)
    }, 1000)
  }

  async _startRecording() {
    try {
      // A fresh stream per recording: holding one open leaves the
      // browser's recording indicator lit while nobody is talking.
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      this._stopListening()
      this._setStatus("Mic blocked", true)
      return
    }

    // Cancelled or released while the permission prompt was up.
    if (!this.listening) {
      this._releaseMic()
      return
    }

    const chunks = []
    this.recorder = new MediaRecorder(this.stream, this._recorderOptions())
    this.recorder.ondataavailable = (event) => {
      if (event.data.size > 0) chunks.push(event.data)
    }
    this.recorder.onstop = () => {
      this._releaseMic()
      this._stopListening()
      if (this.discarded) return

      const blob = new Blob(chunks, { type: this.recorder.mimeType })
      if (blob.size === 0) {
        this._setStatus("Didn't catch that", true)
        return
      }
      this._submit({ audio: blob })
    }
    this.recorder.start()
  }

  // Opus in WebM where it exists (small and well handled), MP4/AAC in
  // Safari, and whatever the browser prefers if it likes neither.
  _recorderOptions() {
    const preferred = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"]
    const supported = preferred.find((type) => MediaRecorder.isTypeSupported?.(type))
    return supported ? { mimeType: supported } : {}
  }

  _releaseMic() {
    this.stream?.getTracks().forEach((track) => track.stop())
    this.stream = null
  }

  _onResult(event) {
    let interim = ""
    for (const result of event.results) {
      if (result.isFinal) this.finalTranscript += result[0].transcript
      else interim += result[0].transcript
    }
    this._setStatus(`“${(this.finalTranscript + interim).trim().slice(-80)}”`)
  }

  _onRecognitionEnd() {
    this._stopListening()
    if (this.discarded) return

    const text = this.finalTranscript.trim()
    if (text.length === 0) return

    this._submit({ transcript: text })
  }

  // ── Posting ────────────────────────────────────────────────────────

  async _submit({ transcript, audio }) {
    this._setStatus(audio ? "Transcribing…" : "Tidying up…")

    // One round trip does every slow job: transcribe if it was audio,
    // clean up the words, and work out which passage they were about.
    const interpreted = await this._interpret({ transcript, audio })

    if (!interpreted?.body && !transcript) {
      // Audio with nothing to show for it — there is no comment to post.
      this._setStatus("Couldn't make that out", true)
      return
    }

    const commentBody = interpreted?.body || this._stripFillers(transcript)
    const anchor = interpreted?.anchor || this._viewportAnchor()

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const body = new FormData()
    body.append("comment_thread[body_markdown]", `🎙️ ${commentBody}`)
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

  // Transcribe, clean up and locate the passage, in one time-boxed
  // request. A failure with a transcript in hand leaves the fallbacks in
  // place; a failure with only audio has nothing to fall back to.
  async _interpret({ transcript, audio }) {
    const controller = new AbortController()
    // Uploading and transcribing audio is a different order of work from
    // rewriting a sentence, and giving up early on it means giving up on
    // the comment entirely.
    const timer = setTimeout(() => controller.abort(), audio ? 25000 : 8000)

    try {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const form = new FormData()
      if (transcript) form.append("transcript", transcript)
      if (audio) form.append("audio", audio, `dictation.${this._extensionFor(audio)}`)
      if (this.excerpt) form.append("excerpt", this.excerpt)

      const response = await fetch(this.dictationUrlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": token, Accept: "application/json" },
        body: form,
        signal: controller.signal
      })
      if (!response.ok) return null

      const { body, anchor_text: anchorText } = await response.json()
      return { body: body || null, anchor: this._resolveAnchor(anchorText) }
    } catch {
      return null
    } finally {
      clearTimeout(timer)
    }
  }

  _extensionFor(blob) {
    const type = (blob.type || "").split(";")[0]
    if (type.includes("mp4")) return "mp4"
    if (type.includes("ogg")) return "ogg"
    if (type.includes("wav")) return "wav"
    if (type.includes("mpeg")) return "mp3"
    return "webm"
  }

  // The span has to exist in the rendered document to be highlighted,
  // and we need to know which copy of it we mean.
  _resolveAnchor(anchorText) {
    if (!anchorText) return null

    const content = document.getElementById("plan-content-body")
    if (!content?.textContent?.includes(anchorText)) return null

    return { text: anchorText, occurrence: this._occurrenceOfNearViewport(content, anchorText) }
  }

  // Fallback tidy-up for when the interpret call fails: drop the tics
  // that stand alone as words and collapse stutters. Conservative on
  // purpose — "like" is a real word ("looks like the API"), so it only
  // goes when it's clearly filler, and nothing here reorders or rewrites.
  _stripFillers(text) {
    const cleaned = (text || "")
      .replace(/\b(?:um+|uh+|er+|hmm+)\b[,]?\s*/gi, "")
      .replace(/\b(?:you know|i mean|sort of|kind of|basically)\b[,]?\s*/gi, "")
      .replace(/\blike\b[,]?\s+(?=like\b)/gi, "")
      .replace(/\b(\w+)(\s+\1\b)+/gi, "$1")
      .replace(/\s{2,}/g, " ")
      .replace(/\s+([,.!?])/g, "$1")
      .trim()

    if (cleaned.length === 0) return text
    return cleaned.charAt(0).toUpperCase() + cleaned.slice(1)
  }

  // The text currently on screen: what the remark is about, the hint that
  // makes transcription get the jargon right, and the only part of the
  // document we send anywhere.
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
