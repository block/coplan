"""CoPlan voice sidecar — fully local speech loop on macOS.

Pipeline: browser mic --WebRTC--> Silero VAD + smart-turn --> MLX Whisper STT
          --> CoPlanAgentBackend --> Kokoro TTS --WebRTC--> browser speaker

The "brain" is deliberately NOT an LLM service: spoken feedback becomes a
CoPlan comment (same event inbox that wakes the plan's agent — see
script/coplan-bridge), and the pipeline speaks a fast acknowledgment
("Got it") within ~1s while the real agent works at its own pace. Doc
edits arrive visually through the plan page's live broadcasts, not through
this audio path.

Providers are Pipecat services, so swapping STT/TTS for hosted ones
(Deepgram, ElevenLabs, ...) is a one-line constructor change — that's the
plugin seam. See voice/README.md for setup.
"""

import asyncio
import os
import random

import aiohttp
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.frames.frames import Frame, TranscriptionFrame, TTSSpeakFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.services.whisper.stt import WhisperSTTServiceMLX, MLXModel
from pipecat.services.openai.tts import OpenAITTSService
from pipecat.transports.network.small_webrtc import SmallWebRTCTransport

COPLAN_BASE = os.environ.get("COPLAN_BASE", "http://localhost:3223")
COPLAN_TOKEN = os.environ["COPLAN_TOKEN"]
PLAN_ID = os.environ["COPLAN_PLAN_ID"]

ACKS = ["Got it.", "On it.", "Sure thing.", "Okay, one sec."]


class CoPlanAgentBackend(FrameProcessor):
    """The brain seam: final transcript in → fast ack + CoPlan comment out.

    Anything smarter (RAG over the doc, direct Q&A without waking the
    agent) slots in here without touching VAD/turn-taking/barge-in.
    """

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)

        if isinstance(frame, TranscriptionFrame) and frame.text.strip():
            # 1. Fast ack — speak before the real work starts.
            await self.push_frame(TTSSpeakFrame(random.choice(ACKS)))
            # 2. Feed the agent through the normal comment loop.
            asyncio.create_task(self._post_comment(frame.text.strip()))
        else:
            await self.push_frame(frame, direction)

    async def _post_comment(self, text: str):
        async with aiohttp.ClientSession() as session:
            await session.post(
                f"{COPLAN_BASE}/api/v1/plans/{PLAN_ID}/comments",
                headers={"Authorization": f"Bearer {COPLAN_TOKEN}"},
                json={"body_markdown": f"🎙️ {text}", "agent_name": "Voice"},
            )


async def main():
    transport = SmallWebRTCTransport(
        params={"audio_in_enabled": True, "audio_out_enabled": True},
        vad_analyzer=SileroVADAnalyzer(),
    )

    stt = WhisperSTTServiceMLX(model=MLXModel.LARGE_V3_TURBO_Q4)

    # Kokoro-FastAPI exposes an OpenAI-compatible /v1/audio/speech —
    # the same constructor pointed at api.openai.com is the hosted swap.
    tts = OpenAITTSService(
        api_key="local",
        base_url=os.environ.get("KOKORO_URL", "http://localhost:8880/v1"),
        voice="af_heart",
        model="kokoro",
    )

    pipeline = Pipeline([
        transport.input(),
        stt,
        CoPlanAgentBackend(),
        tts,
        transport.output(),
    ])

    task = PipelineTask(pipeline, params=PipelineParams(allow_interruptions=True))
    await PipelineRunner().run(task)


if __name__ == "__main__":
    asyncio.run(main())
