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

  // Peak deviation from silence, on the 0–128 scale of the time-domain
  // samples. Room tone sits in the low single digits; speech is well
  // past 20. Anything under this never made it to the microphone.
  static SILENCE_PEAK = 6

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
    this._closeEar()
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
        else if (this.ear) {
          clearTimeout(this.holdTimer)
          this._closeEar()
        }
        return
      }
      if (event.repeat || this.pushToTalk || this.listening) return
      if (this._isTyping() || event.metaKey || event.ctrlKey || event.altKey) return

      // Capture from the instant of the press. Deciding whether the press
      // means "talk" takes 350ms and opening the microphone takes a couple
      // hundred more — people start talking at the press, and "oh, I meant
      // both of them" is over before a capture that waits for both. If
      // this turns out to be a tap or a selection, the take is discarded
      // unheard.
      if (this.mode === "record") this._openEar()

      this.holdTimer = setTimeout(() => {
        // Extending a selection with Shift+arrow or Shift+click also
        // holds Shift; if text got selected, that's what was happening.
        if (!window.getSelection()?.isCollapsed) {
          this._closeEar()
          return
        }
        this.pushToTalk = true
        this._start()
      }, this.HOLD_DELAY)
    }

    this._onKeyUp = (event) => {
      if (event.key !== "Shift") return
      clearTimeout(this.holdTimer)
      if (!this.pushToTalk) {
        this._closeEar() // a tap: whatever the ear caught is dropped
        return
      }

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
    this.recorder = null
    this.peakLevel = 0
    this.meterLive = false
    this.stopRequested = false
    this.listening = true
    this.buttonTarget.classList.add("voice-btn--listening")
    this._startTicking()

    if (this.mode === "record") this._startRecording()
    else this.recognition.start()
  }

  _stop() {
    if (!this.listening) return

    if (this.mode !== "record") {
      this.recognition?.stop() // → onend posts
      return
    }

    // Released while the microphone is still opening (the permission
    // prompt, usually). The take isn't lost — as soon as the recorder
    // exists it is stopped and whatever was captured goes out.
    if (!this.recorder) {
      this.stopRequested = true
      return
    }

    this.recorder.stop() // → onstop posts
  }

  // Discards whatever was captured rather than posting it.
  _cancel() {
    clearTimeout(this.holdTimer)
    this.pushToTalk = false
    this._closeEar()
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

  // A capture begun before the decision to keep it: stream + recorder,
  // buffering silently, no UI. Adopted by _startRecording when the hold
  // is confirmed; discarded unheard by _closeEar when it turns out to be
  // a tap, a selection, or a shortcut. The cost of a false start is a
  // blink of the browser's recording indicator.
  _openEar() {
    if (this.ear) return

    const ear = { chunks: [], closed: false }
    ear.ready = (async () => {
      try {
        ear.stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      } catch {
        ear.error = true
        return
      }
      if (ear.closed) {
        ear.stream.getTracks().forEach((track) => track.stop())
        ear.stream = null
        return
      }
      ear.recorder = new MediaRecorder(ear.stream, this._recorderOptions())
      ear.recorder.ondataavailable = (event) => {
        if (event.data.size > 0) ear.chunks.push(event.data)
      }
      ear.recorder.start()
    })()
    this.ear = ear
  }

  _closeEar() {
    const ear = this.ear
    this.ear = null
    if (!ear) return

    ear.closed = true
    if (ear.recorder && ear.recorder.state !== "inactive") ear.recorder.stop()
    ear.stream?.getTracks().forEach((track) => track.stop())
  }

  async _startRecording() {
    const ear = this.ear
    this.ear = null
    let chunks = []

    if (ear) {
      // Push-to-talk: the ear has been capturing since the keydown.
      await ear.ready
    } else {
      // The button path has no press-to-decide gap, so it captures from
      // the click itself. A fresh stream per recording either way:
      // holding one open leaves the recording indicator lit while
      // nobody is talking.
      try {
        this.stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      } catch {
        this._stopListening()
        this._reportMiss("Mic blocked")
        return
      }
    }

    if (ear?.error) {
      this._stopListening()
      this._reportMiss("Mic blocked")
      return
    }

    // Cancelled while the permission prompt was up.
    if (!this.listening) {
      if (ear) {
        ear.closed = true
        ear.recorder?.stop()
        ear.stream?.getTracks().forEach((track) => track.stop())
      }
      this._releaseMic()
      return
    }

    if (ear) {
      this.stream = ear.stream
      this.recorder = ear.recorder
      chunks = ear.chunks
    } else {
      this.recorder = new MediaRecorder(this.stream, this._recorderOptions())
      this.recorder.ondataavailable = (event) => {
        if (event.data.size > 0) chunks.push(event.data)
      }
    }

    this._meterLevels()

    this.recorder.onstop = () => {
      // The silence verdict is only trustworthy if the meter actually
      // ran. A dead meter reads 0 for a recording full of speech — when
      // in doubt, send it; the server's echo check is the backstop.
      const heardSomething = !this.meterLive || this.peakLevel >= this.constructor.SILENCE_PEAK
      this._releaseMic()
      this._stopListening()
      if (this.discarded) return

      const blob = new Blob(chunks, { type: this.recorder.mimeType })
      // Sending silence is worse than sending nothing: the transcriber
      // answers it by repeating the context we gave it, which arrives
      // looking like a real remark. Catch it here, before the round trip.
      if (blob.size === 0 || !heardSomething) {
        this._reportMiss("Hmm — didn't hear anything")
        return
      }
      this._submit({ audio: blob })
    }

    if (this.recorder.state !== "recording") this.recorder.start()

    // Released while the microphone was still opening: finish the take
    // now that there is one, posting whatever the ear caught.
    if (this.stopRequested) {
      this.stopRequested = false
      this.recorder.stop()
    }
  }

  // Tracks the loudest thing in the recording, and drives the button's
  // pulse so there is some sign it can hear you — the recording path has
  // no interim captions to show.
  //
  // The meter's verdict only counts while `meterLive` is true. An
  // AudioContext starts suspended unless the browser saw a qualifying
  // user gesture, and Chrome does not count a bare Shift keydown as one —
  // so on the push-to-talk path the context routinely comes up dead, and
  // a suspended analyser reads as perfect silence. Trusting that reading
  // meant refusing recordings people were audibly speaking into.
  _meterLevels() {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext
    this.meterLive = false

    try {
      this.audioContext = new AudioContextClass()
      if (this.audioContext.state !== "running") this.audioContext.resume()?.catch?.(() => {})

      const analyser = this.audioContext.createAnalyser()
      analyser.fftSize = 512
      this.audioContext.createMediaStreamSource(this.stream).connect(analyser)

      const samples = new Uint8Array(analyser.fftSize)
      const sample = () => {
        if (!this.listening) return

        // Only a running context produces real samples; a suspended one
        // is indistinguishable from a silent room.
        if (this.audioContext.state === "running") this.meterLive = true

        analyser.getByteTimeDomainData(samples)
        let peak = 0
        for (const value of samples) peak = Math.max(peak, Math.abs(value - 128))

        this.peakLevel = Math.max(this.peakLevel, peak)
        this.buttonTarget.style.setProperty("--voice-level", Math.min(peak / 40, 1).toFixed(2))
        requestAnimationFrame(sample)
      }
      requestAnimationFrame(sample)
    } catch {
      // Metering is a check on the recording, not part of making it. If
      // it can't run, assume there was speech — refusing to post what
      // somebody said is a worse failure than sending silence.
      this.meterLive = false
    }
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
    this.audioContext?.close()
    this.audioContext = null
    this.buttonTarget.style.removeProperty("--voice-level")
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
      // The server distinguishes "heard nothing" from "couldn't reach the
      // transcriber", and which one it was changes what you'd do next.
      this._reportMiss(interpreted?.error || "Couldn't make that out")
      return
    }

    const commentBody = interpreted?.body || this._stripFillers(transcript)
    let anchor = interpreted?.anchor || this._viewportAnchor()

    let response = await this._postComment(commentBody, anchor)

    // 422 means the server refused the pin: the anchor renders on screen
    // but doesn't resolve in the plan source, so the comment would have
    // been invisible. The words are still good — pin them to the nearest
    // heading instead, which always resolves.
    if (response?.status === 422 && anchor) {
      const fallback = this._viewportAnchor()
      anchor = fallback && fallback.text !== anchor.text ? fallback : null
      response = await this._postComment(commentBody, anchor)
    }

    if (!response?.ok) {
      this._setStatus("Couldn't send", true)
      return
    }

    // Show where it landed. The speaker never picked a spot on the page —
    // the model did — so "comment posted" alone leaves them hunting for
    // it (or, pinned below the fold, believing it never posted). Render
    // the response's streams now rather than waiting on the cable echo,
    // then scroll to the thread and open it.
    const streams = await response.text()
    window.Turbo?.renderStreamMessage(streams)
    const threadId = streams.match(/comment_thread_([0-9a-f-]{36})/)?.[1]
    if (threadId) {
      document.dispatchEvent(new CustomEvent("coplan:open-thread", { detail: { threadId } }))
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

  async _postComment(commentBody, anchor) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const body = new FormData()
    body.append("comment_thread[body_markdown]", `🎙️ ${commentBody}`)
    if (anchor) {
      body.append("comment_thread[anchor_text]", anchor.text)
      body.append("comment_thread[anchor_occurrence]", anchor.occurrence)
    }

    try {
      return await fetch(this.urlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": token, "Accept": "text/vnd.turbo-stream.html, text/html" },
        body
      })
    } catch {
      return null
    }
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
      if (!response.ok) {
        const { error } = await response.json().catch(() => ({}))
        return { body: null, anchor: null, error }
      }

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
    const visible = blocks.filter((el) => this._readablyVisible(el))
    const text = (visible.length > 0 ? visible : blocks.slice(0, 20))
      .map((el) => el.textContent.trim())
      .filter(Boolean)
      .join("\n")

    return text.length > 0 ? text : null
  }

  // On screen enough to be read, not merely intersecting the viewport. A
  // paragraph with one line poking over the fold used to count, the model
  // would quote it, and the comment pinned somewhere the person had never
  // seen. A block qualifies when what's in view is most of the block or a
  // real slice of the screen — a full-viewport paragraph passes, a
  // two-pixel sliver doesn't.
  _readablyVisible(el) {
    const rect = el.getBoundingClientRect()
    const visibleHeight = Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0)
    if (visibleHeight <= 0) return false
    return visibleHeight >= Math.min(rect.height * 0.5, window.innerHeight * 0.2)
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

  // A miss in a voice flow is reported by voice: you were talking, not
  // watching a status chip in the corner. Same words on screen and out
  // loud, so neither channel contradicts the other.
  _reportMiss(text) {
    this._setStatus(text, true)
    this._speak(text.replace("—", ","))
  }

  _setStatus(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("voice-status--error", isError)
  }
}
