# Agent collaboration: the live feedback loop

How an agent that authored a plan hears about your comment within a
second, shows you it's working, replies, and edits the doc while you
watch. Design docs (options + tradeoffs) live in CoPlan itself — see the
"Agent Collaboration in CoPlan" umbrella plan.

## The loop

1. A human comments (typed, or spoken via the mic button).
2. The comment fans out to the **agent event inbox** (`AgentEvent`) of
   every agent session on the plan — never back to the actor itself.
3. The agent (or `script/coplan-bridge` on its behalf) is long-polling
   `GET /api/v1/agent/events` and wakes.
4. It flips its **agent session** to `active` (the presence pill humans
   see), replies on the thread narrating what it'll change, PUTs the
   edit, and lands on `complete`.
5. Every open tab gets the new content over Turbo Streams; the sections
   that changed **flash** — word-level ins/del for edited paragraphs —
   then settle.

The delivery is pull-based on purpose: agents run on laptops behind NAT,
so CoPlan never assumes it can push. Same endpoint serves long-poll
(plain JSON, curl-friendly) and SSE (`Accept: text/event-stream`).
Cursor = last event id (UUIDv7, time-ordered); delivery is
at-least-once with explicit ack.

## Capacity: attached agents vs. everyone else

Every attached agent holds a Rack thread for the life of its connection,
and `RAILS_MAX_THREADS` is small (3 by default). Measured on this
codebase: with three agents attached and no budget, the app **stopped
serving pages** — a plain page load timed out after 10s.

So `AgentEventBus` caps concurrent held connections at
`RAILS_MAX_THREADS - 2` (override with `COPLAN_MAX_AGENT_STREAMS`),
always leaving threads for ordinary traffic. Over budget:

- **long-poll** answers immediately with `"throttled": true` — the
  client falls back to its own polling cadence, nothing breaks
- **SSE** is refused with `503` + `Retry-After`, pointing at long-poll

With the budget on, the same three-agent load serves a page in ~25ms.

Waiting is signal-driven, not polled: `AgentEvents::Publish` signals the
bus, so a parked long-poll returns in **~180ms** end-to-end from comment
to delivery. Waiters still wake every few seconds to catch writes from
another Puma worker, so cross-process delivery degrades to that interval
rather than failing.

The honest ceiling: this is thread-per-agent. It's fine for a team, not
for hundreds of concurrent attached agents — that would want a real
pub/sub transport rather than held Rack threads.

Full API reference: `GET /agent-instructions` → "Live Collaboration".

## Attaching (the normal case)

An agent that is **alive and watching** doesn't need waking — it needs
interrupting. `script/coplan-attach` holds one server-driven SSE
connection and prints the moment something happens: no interval to tune,
no daemon, no config file, no harness integration.

```bash
export COPLAN_BASE=http://localhost:3222 COPLAN_TOKEN=<token>

# Turn-based agents: blocks until the first event, prints a brief, acks, exits.
script/coplan-attach --plan <plan-id> --name Claude --once

# Or stay attached and stream everything:
script/coplan-attach --plan <plan-id> --name Claude
```

`--once` is the shape a harness wants: run it as a tool call, get woken
by its output, act on the brief, run it again. While attached you hold
the presence pill; Ctrl-C detaches cleanly. `--timeout N` exits 64 if
nothing arrives, so a supervising loop can decide when to stop watching.

It's a thin convenience over the API — an agent that can curl can do the
same thing straight from `/agent-instructions`, and doesn't need this
script at all.

## What the harness must provide

CoPlan can deliver an event in ~180ms; it cannot start the model's next
turn. That last inch of wiring belongs to the harness, and it is the
whole game: an event printed by a background process nobody wakes up for
is transport without collaboration.

Field report (Amp, local thread, 2026-08-19): it held the SSE stream
fine, received every event with full context, and sat there — the model
never woke, and the human had to nudge it by hand before it could act on
comments that had been buffered for minutes.

The shapes that close the loop, most portable first:

1. **Blocking tool call.** Run `coplan-attach --once` (or the long-poll
   curl) as a foreground tool call; the event returns as tool output.
   Works in every harness; occupies the turn while waiting.
2. **Background process + exit re-invocation.** `coplan-attach --once`
   in the background; the process exiting is the wake. Requires the
   harness to re-invoke the model when a background task completes —
   Claude Code does, most others don't.
3. **Sidecar resume.** `script/coplan-bridge` drains the inbox from
   outside the harness and injects each event via a resume-with-message
   command (adapter table below).

A harness with none of these can still be a correct — just not live —
collaborator: the inbox is durable, so drain it with `wait=0` at the
start of each turn.

Presence stays honest whichever way delivery goes. An event flips the
session to `pending`, whose pill says "Waking Claude…" — a claim about
what the *server* did, not the agent — and holds for at most 30 seconds
before going stale. Only the agent itself can claim to be working, by
PATCHing `active`. And the API refuses to *claim* a session into a turn
state like `awaiting_input`, so an agent can't park an unearned "asked a
question" pill on arrival.

One open design question (Amp's ask): an outbound **webhook wake** — the
session registers a wake URL and CoPlan POSTs a signed "you have inbox
items" ping, with the agent still pulling and acking through the cursor
API. That would serve hosted agents (Amp orbs and the like) that can
receive HTTP but can't hold connections or be exec-resumed. Not built;
pull remains the default.

## The bridge (only for agents that have exited)

If nothing is running, something has to start it. `script/coplan-bridge
--config bridge.json` claims sessions on the plans you list, drains the
inbox, and injects each event into your harness via a "resume session
with message" command. It flips the pill to `active` before the harness
even boots, so the human sees life immediately.

This is strictly the cold-start path. If you keep a session attached
while you work, skip the bridge entirely.

```json
{
  "base_url": "http://localhost:3222",
  "token": "<api token from Settings → API Tokens>",
  "agent_name": "Claude",
  "plans": ["<plan-id>"],
  "adapter": "claude",
  "harness_session": "<session id to resume>"
}
```

### Per-harness adapters

| `adapter` | Command shape (exec-resume, works everywhere) | Better, push-into-live-session surface |
|---|---|---|
| `claude` | `claude -p --resume <session> <prompt>` | Channels MCP server (research preview) or Agent SDK streaming input |
| `codex` | `codex exec resume <session> <prompt>` | `codex app-server` → `turn/start` / `turn/steer` |
| `goose` | `goose run --name <session> --resume -t <prompt>` | `goose serve` (ACP) → `session/prompt` |
| `openhands` | `openhands --headless --resume <session> -t <prompt>` | agent-server `POST /conversations/:id/events` |
| `amp` | `amp threads continue <session> -x <prompt>` | `amp -x --stream-json-input` with `"steer": true` |
| `demo` | in-process deterministic agent (ack → reply → small edit) — no harness or tokens needed | — |

Unattended runs need each harness's permission-relaxation flag
(`--permission-mode acceptEdits`, `--full-auto`, `GOOSE_MODE=auto`, …).
The default `claude` adapter uses `acceptEdits`; choose your own posture
deliberately — the bridge never escalates beyond what the config says.

An agent doesn't need the bridge at all: any agent that can run curl in
a loop can follow the "Live Collaboration" section of
`/agent-instructions` directly.

## Demoing locally

```bash
bin/rails server -p 3222
# Make a token (Settings → API Tokens) for the user who authors the plan.

# Terminal 2 — the "agent":
script/coplan-bridge --config bridge.json    # adapter: "demo" for zero-cost

# Browser: open the plan, comment on a stiff sentence
# ("this is way too formal"). Watch: pill appears → reply lands →
# section flashes with word-level diffs.
```

Voice: the mic button on the plan page (Chrome) speaks your feedback into
the same loop, with spoken "Got it." / "Done — take a look." cues. The
higher-fidelity local pipeline (Pipecat + MLX Whisper + Kokoro) lives in
`voice/`.
