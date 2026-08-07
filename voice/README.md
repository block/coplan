# CoPlan voice sidecar

Two voice tiers, one loop. Both turn speech into a plan comment, which
wakes the plan's agent through the event inbox (`GET /api/v1/agent/events`
— see `/agent-instructions` and `script/coplan-bridge`); the agent's reply
and edits arrive visually via the plan page's live broadcasts, with the
presence pill and diff flashes doing the "I heard you" work.

## Tier 1 — zero-install (already on)

The mic button on the plan page uses browser-native speech recognition
(on-device in Chrome 139+) and `speechSynthesis` for the "Got it." /
"Done — take a look." cues. No setup; weakest voices; Chrome recommended
(Safari's Web Speech is unreliable).

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
