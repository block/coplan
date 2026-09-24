# Agent collaboration: the live feedback loop

How an agent that authored a plan hears about your comment within a
second, shows you it's working, replies, and edits the doc while you
watch. Design docs (options + tradeoffs) live in CoPlan itself — see the
"Agent Collaboration in CoPlan" umbrella plan.

## The loop

1. A human comments (typed, or spoken via the mic button).
2. The comment fans out to the **agent event inbox** (`AgentEvent`) of
   every agent session on the plan — never back to the actor itself.
3. The agent (or `coplan-bridge` on its behalf) is long-polling
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

## Waiting while an agent turn is active

An agent that is **currently alive and explicitly waiting** can receive an
event as ordinary tool output. `coplan-attach` holds one server-driven SSE
connection and prints the moment something happens. That handles event
delivery inside the current turn; it does not arrange a future model turn or
make a completed conversation resumable.

The runtime contract is `/agent-instructions`, not a repository checkout.
Production agents either use the HTTP protocol there or download the optional
tools served at `/agent-tools/coplan-attach`, `/agent-tools/coplan_session.rb`,
and `/agent-tools/coplan-bridge`. Their source lives in `engine/agent_tools/`.
The top-level `script/coplan-*` files are thin shims for local development and
appear only in the local demo below.

`--once --timeout N` is the safe foreground shape: run it as a tool call only
for an explicit wait/monitor request, act on any returned brief, and run it
again only while that request remains active. While attached you hold the
presence pill; Ctrl-C detaches cleanly. A timeout exits 64 if nothing arrives.
The unbounded streaming form belongs under an external supervisor that owns
its lifecycle and has a real way to re-enter the model.

The served tool is a thin convenience over the API. An agent that can make
HTTP requests can follow `/agent-instructions` directly and does not need it.

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

1. **Blocking tool call.** Run `coplan-attach --once --timeout N` (or a
   bounded long-poll curl) as a foreground tool call; the event returns as
   tool output. Use this only while the user explicitly asked the agent to
   wait or monitor; it occupies the turn while waiting.
2. **Background process + exit re-invocation.** `coplan-attach --once`
   in the background; the process exiting is the wake. Requires the
   harness to demonstrably re-invoke the model when a background task
   completes. A terminal notification or retained process is not enough.
3. **Sidecar resume.** `coplan-bridge` drains the inbox from outside
   the harness and invokes a per-harness resume-with-message command for a
   known existing session (adapter table below). Its ACP mode is different:
   it creates and owns a separate dedicated agent, so it is not a way to
   attach the primary authoring conversation.
4. **Webhook wake.** For hosted agents that can receive HTTP but can't
   hold connections or be exec-resumed (Amp orbs, scheduled runners):
   claim the session with a `wake_url` and CoPlan POSTs a signed "you
   have inbox items" ping there on every event (`X-CoPlan-Signature`:
   HMAC-SHA256 of the body with the `wake_secret` returned once at
   registration; `event_id` for dedupe; retried with backoff). The ping
   carries no payload — the agent pulls and acks through the cursor API
   like every other transport, so at-least-once semantics and the
   authority model don't fork. Two guardrails on the URL itself: hosts
   must resolve to public address space (checked at registration and
   again before every POST; deployments override via
   `config.wake_url_policy`), and a URL that eats several entire retry
   runs is presumed dead and unregistered — mirroring how expired web
   push subscriptions are destroyed rather than hammered forever.

A harness with none of these can still be a correct — just not live —
collaborator: the inbox is durable, so drain it with `wait=0` at the
start of each turn.

Presence stays honest whichever way delivery goes, on two principles:

- **A wake is only attempted where a path for it exists.** SSE
  heartbeats and long-poll parks stamp the session's transport clock;
  an event only flips a session to `pending` if a connection touched
  transport recently or a wake URL is registered. No path → the event
  just queues, and the pill doesn't move.
- **Wakeability is demonstrated, never declared.** A session that has
  never answered a wake gets no promise: its first `pending` keeps the
  plain-name pill while the wake quietly tests it. Once it has moved
  itself out of `pending` (the one observable proof that delivery became
  a model turn), later wakes earn "Waking Claude…". Either way `pending`
  holds for at most 30 seconds before going stale, only the agent itself
  can claim to be working (`active`), and the API refuses to *claim* a
  session into a turn state like `awaiting_input` — no unearned "asked a
  question" pill on arrival.

## The resume bridge (only for known existing sessions)

If nothing is running, something has to start it. The bridge claims
sessions on the plans you list, drains the inbox, and injects each event
with a "resume session with message" command. It flips the pill to `active`
before the harness resumes, so the human sees life immediately.

This is strictly the cold-start path. If you keep a session attached
while you work, skip the bridge entirely.

The simple path is flags — no config file, but a known resumable session id
is required:

```bash
export COPLAN_BASE=http://localhost:3222 COPLAN_TOKEN=<token>
coplan-bridge --adapter claude --session <session-id> --plan <plan-id> --name Claude
```

An adapter must always be named — there is no default — and it is validated
at startup, not at the first wake. Setups
worth writing down go in a config file, with the same keys. Precedence
is flags > `$COPLAN_BASE`/`$COPLAN_TOKEN` > file, `--plan` replaces the
file's plan list outright, and the bridge prints which config file it
loaded — a leftover `~/.config/coplan/bridge.json` never silently
steers a flags-only run:

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

### Per-harness resume adapters

The following adapters re-enter an existing session and require its id.

| `adapter` | Command shape | Notes |
|---|---|---|
| `claude` | `claude -p --resume <session> <prompt>` | exec-resume |
| `codex` | `codex exec resume <session> <prompt>` | exec-resume |
| `goose` | `goose run --name <session> --resume -t <prompt>` | exec-resume |
| `openhands` | `openhands --headless --resume <session> -t <prompt>` | exec-resume |
| `amp` | `amp threads continue <session> -x <prompt>` | exec-resume into a local thread. For Amp **orbs**, skip the bridge: register the orb's `amp.createWebhook` URL as the session's `wake_url`. |
| `demo` | in-process deterministic agent (ack → reply → small edit) — no harness or tokens needed | — |

### Dedicated ACP agents (separate deployment mode)

The bridge still has an ACP adapter for an operator who intentionally wants a
standing CoPlan worker or reviewer. It starts a harness ACP server, calls
`session/new`, and pushes plan events into the new session as prompt turns.
That agent has its own identity and lifecycle; it is not the primary author
and it does not attach or resume the conversation that launched the bridge.
Keep ACP out of automatic attachment guidance and provision it explicitly:

```bash
coplan-bridge --acp "goose acp" --plan <plan-id> --name "Review agent"
```

Unattended runs need each harness's permission-relaxation flag
(`--permission-mode acceptEdits`, `--full-auto`, `GOOSE_MODE=auto`, …).
The stock `claude` command template uses `acceptEdits`; choose your own
posture deliberately — the bridge never escalates beyond what the
config says.

An agent doesn't need the bridge to drain events during its current turn: it
can follow the "Live Collaboration" protocol in `/agent-instructions`
directly. That becomes a durable attachment only when the harness can turn
the wait's completion into another model turn. A foreground loop that merely
blocks, or a background loop that only writes a notification, is not a wake
path.

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
