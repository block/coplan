# CoPlan voice sidecar

Two voice tiers, one loop. Both turn speech into a plan comment, which
wakes the plan's agent through the event inbox (`GET /api/v1/agent/events`
— see `/agent-instructions` and `script/coplan-bridge`); the agent's reply
and edits arrive visually via the plan page's live broadcasts, with the
presence pill and diff flashes doing the "I heard you" work.

## Tier 1 — zero-install (already on)

The mic button on the plan page captures one of two ways, decided by
whether an AI provider is configured (`CoPlan::Ai.available?`, passed to
the Stimulus controller as `transcription-value`):

- **Record and transcribe** (default when a provider is configured).
  `MediaRecorder` captures Opus in WebM, or MP4/AAC in Safari, and posts
  it to `POST /plans/:id/dictations`, which runs it through
  `gpt-4o-transcribe` (override with `COPLAN_TRANSCRIBE_MODEL`). Works in
  every browser with a microphone. The text that was on screen is passed
  as the transcription prompt, which is what makes product names, jargon
  and figures come back as themselves instead of phonetic guesses.
  Costs a round trip, and there are no live captions while you talk.
- **Browser recognition** (fallback). Web Speech API, on-device in
  Chrome 139+. Instant, free, interim text as you speak — and clearly
  worse on anything domain-specific. Chrome only in practice; Safari's
  implementation is unreliable.

`speechSynthesis` handles the "Got it." / "Done — take a look." cues in
both cases.

### Making tier 1 better

Roughly in order of value per unit of work:

1. **Both at once.** Run recognition for live captions *and* record for
   the transcript that actually gets posted. Restores the "it's hearing
   me" feedback the recording path gives up, at the cost of two mic
   consumers in one page.
2. **A real hint, not just the viewport.** The prompt currently gets the
   visible text. The plan title, section headings, and recent comment
   text are all cheap to add and all full of the words being spoken.
3. **Streaming transcription.** `gpt-4o-transcribe` over a WebSocket, or
   the tier 2 sidecar below, turns a 2–4s wait into a running transcript.
4. **Show the transcript before posting.** A two-second window to see
   what it heard, with the comment posting itself if you say nothing —
   catches the "that isn't what I said" case without adding a step.
5. **Silence trimming and a level meter.** Cheaper uploads, and a mic
   that visibly responds to your voice is the clearest possible signal
   that it is working.

## Tier 2 — local OSS pipeline (this directory)

Pipecat + Silero VAD + MLX Whisper (STT) + Kokoro-82M (TTS), browser ↔
sidecar over serverless WebRTC. All local on Apple Silicon; expect
~0.5–1s from end-of-speech to the audible ack once models are warm
(~30s cold start).

```bash
# 1. Kokoro TTS server (OpenAI-compatible on :8880)
uvx kokoro-fastapi   # or: docker run -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu

# 2. The sidecar
python -m venv .venv && source .venv/bin/activate
pip install "pipecat-ai[webrtc,silero,whisper-mlx,openai]" aiohttp

COPLAN_BASE=http://localhost:3223 \
COPLAN_TOKEN=<api token> \
COPLAN_PLAN_ID=<plan id> \
python bot.py
```

Point the browser client (Pipecat's `SmallWebRTCTransport` ships a JS SDK)
at the sidecar's offer endpoint. Barge-in is on (`allow_interruptions`);
pin pipecat past the ~0.0.62 SmallWebRTC audio regression.

## The plugin seam

- **Providers**: STT/TTS are Pipecat services — swapping MLX Whisper →
  Deepgram or Kokoro → ElevenLabs is a one-line constructor change
  (`OpenAITTSService` pointed at a different `base_url` already covers
  any OpenAI-compatible vendor).
- **The brain**: `CoPlanAgentBackend` in `bot.py` is the only
  CoPlan-aware piece — transcript in, fast-ack + comment out. Smarter
  behavior (doc Q&A without waking the agent, richer spoken summaries
  when the agent finishes) belongs there.

Upgrade paths per the voice design plan: Kyutai STT 1B via MLX for true
streaming transcription; Kyutai TTS for token-streaming readbacks; Piper
for a sub-100ms ack voice.
