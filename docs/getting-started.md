# Getting Started — a friendly tour

This is the gentle, read-it-top-to-bottom introduction to the Agent Steering Service.
If you want the dense reference (every API field, every config key, production notes), see the
[README](../README.md). If you want to *understand what this thing is and how it works* in one
sitting, you're in the right place.

---

## 1. What is this, in one breath?

It's a **remote control for AI agents**.

An AI agent doesn't finish in a single request — it loops: think, call a tool, think again, call
another tool, for minutes or hours. While that loop is running you often need to reach in and
change things: *pause it, point it at a new goal, or stop it entirely.* This service is the
control plane that lets an operator do exactly that, **while the agent is still running**.

Think air-traffic control. The planes (agent loops) fly themselves. The tower (this service)
doesn't fly them, but it can tell any plane to hold, divert, or land — and the plane obeys on its
next move.

> It's a **learning scaffold**, not a production system. It runs entirely on your laptop with no
> cloud account. The patterns are real; the shortcuts are documented.

---

## 2. The problem it solves

Imagine you kicked off an agent with *"summarize these 200 documents."* Five minutes in you
realize you actually wanted translations, not summaries. Or it's clearly going off the rails and
burning money. You have three things you'd want to do:

| You want to… | The command | What happens |
|---|---|---|
| Take a breath | **Pause** | The loop stops doing work but keeps its place. Costs nothing while parked. |
| Change the goal | **Redirect** | Hand it a new instruction; it picks that up and keeps going. |
| Stop for good | **Kill** | The loop ends cleanly. |
| Carry on | **Resume** | Un-pause and continue from exactly where it stopped. |

Doing this safely — across restarts, with two operators possibly clicking buttons at the same
time — is the whole game.

---

## 3. The one big idea (read this twice)

The trick that makes everything work: **control and execution are kept in two separate places.**

```
   ┌────────────────────────┐         ┌──────────────────────────┐
   │   AgentRunEntity        │  reads  │   AgentOrchestrator       │
   │  (the CONTROL state)    │◄────────│   (the EXECUTION loop)    │
   │                         │         │                          │
   │  Status: Running        │         │  while (true):            │
   │  CurrentStep: 3         │         │    read entity            │
   │  Instruction: "..."     │         │    obey what it says      │
   │  AuditLog: [...]        │         │    do one step            │
   └────────────────────────┘         └──────────────────────────┘
            ▲
            │ signals (Pause / Resume / Kill / Redirect)
            │
        SteeringApi  ◄──── operator's HTTP request
```

- **The Entity is the source of truth for *what should be happening*** — is this run Running or
  Paused? What step is it on? What's the current instruction? It holds the *intent*. Crucially,
  the runtime processes its operations **one at a time**, so even if two commands arrive together,
  the state can never get scrambled.

- **The Orchestrator is *what's actually happening*** — the loop that does the work. It doesn't
  decide anything on its own. Every iteration it asks the entity *"what should I be doing?"* and
  obeys.

So "steering" an agent is never a scary direct interrupt. The Steering API just **updates the
entity's intent**, and the loop notices on its next read. Clean and race-free by construction.

(Both of these are **Durable Functions** building blocks — an *Entity* and an *Orchestrator*. The
"durable" part means their state is checkpointed to storage, so a run survives the host
restarting. That's why a paused agent is still paused tomorrow.)

---

## 4. Follow one run, start to finish

This is the demo (`demo.ps1`) told as a story. It's the fastest way to *get* the model.

**① Start.** An operator POSTs `{ "instruction": "summarize the docs", "maxSteps": 10 }`.
The API spins up a new orchestrator and signals the entity `Start`. The entity flips to
`Running`. You get back a `runId`.

**② Running.** The loop wakes up, reads the entity (`Running`, step 0), and does one "tool step"
— in this scaffold that's a simulated 50 ms of work; in real life it'd be an LLM call or a
sandboxed script. Then it tells the entity `AdvanceStep`, waits one second (a *durable* timer),
and loops. Step 1, step 2, step 3… each one logged to the audit trail.

**③ Pause.** The operator POSTs `{ "action": "Pause" }`. The API signals the entity → status
becomes `Paused`. On its next read the loop sees `Paused` and **parks itself on an event** — it
literally stops consuming compute and waits to be woken. Nothing burns while paused.

**④ Redirect (while paused).** The operator POSTs
`{ "action": "Redirect", "newInstruction": "translate the docs instead" }`. This just rewrites
the entity's `Instruction` field. The loop is still parked — it hasn't seen it yet.

**⑤ Resume.** The operator POSTs `{ "action": "Resume" }`. Two things happen: the entity flips
back to `Running`, **and** the API fires the wake-up event the parked loop was waiting for. The
loop springs back to life, re-reads the entity, and now its instruction is *"translate the docs
instead."* It carries on from the same step it paused at — new goal, same place.

**⑥ Kill.** The operator POSTs `{ "action": "Kill" }`. Entity → `Killed`. The loop reads that and
returns cleanly. Done.

Throughout, every transition is appended to the entity's `auditLog`, so
`GET /api/runs/{id}` shows you the whole story:

```
START instruction='summarize the docs' maxSteps=10
STEP 1/10
STEP 2/10
PAUSE
REDIRECT -> 'translate the docs instead'
RESUME
STEP 3/10
KILL
```

That sequence *is* the product. Read it once and the architecture clicks.

---

## 5. Try it yourself in ~5 minutes

You need three things installed: **.NET 8 SDK**, **Azure Functions Core Tools v4** (`func`), and
**Azurite** (a tiny local storage emulator that Durable Functions needs).

```bash
# one-time installs
npm install -g azure-functions-core-tools@4
npm install -g azurite
```

Then, from the repo root, in three terminals:

```bash
# Terminal 1 — local storage
azurite

# Terminal 2 — the service
cp local.settings.json.example local.settings.json   # first run only
func start                                            # serves on http://localhost:7071

# Terminal 3 — drive the demo
pwsh ./demo.ps1
```

You'll watch the run advance ~one step per second, pause on command, keep its redirected
instruction after resume, and stop on kill — with the full audit trail printed at each stage.

Prefer clicking through requests by hand? Open `demo.http` in VS Code (REST Client extension) and
fire them one at a time.

**No cloud account, no Redis, no Cosmos needed** to do any of this — see §7 for why.

---

## 6. The four ways to talk to it

Everything is plain HTTP under `/api`:

| Do this | Request | Notes |
|---|---|---|
| Start a run | `POST /api/runs` | Body: `{ "instruction": "...", "maxSteps": 10 }`. Optional `Idempotency-Key` header (see §8). |
| Steer a run | `POST /api/runs/{id}/steer` | Body: `{ "action": "Pause\|Resume\|Kill\|Redirect", "newInstruction": "..." }`. |
| Check a run | `GET /api/runs/{id}` | Current status, step, instruction, and the audit trail. |
| Read its history | `GET /api/runs/{id}/history` | The event-sourced log of every step and command. |

---

## 7. Where the moving parts live

A quick map so you know which file to open. Each part has a single, clear job.

| File | Its one job |
|---|---|
| `Functions/SteeringApi.cs` | The front door. Turns HTTP requests into entity signals + wake-up events. |
| `Functions/AgentRunEntity.cs` | The **control state** — the source of truth for one run. |
| `Functions/AgentOrchestrator.cs` | The **agent loop** — reads the entity each turn and obeys. |
| `Functions/ToolActivities.cs` | Where the actual tool work runs (and where retries/timeouts live). |
| `Models/` | The plain data shapes: run state, request bodies, history events. |
| `Services/` | Pluggable stores (idempotency, steer-lock, run history) — see below. |
| `Program.cs` | Wires it all together and picks store implementations. |

---

## 8. The two safety guards (and why they're different)

Concurrency is where control planes get subtle. There are **two distinct guards** here — it's
worth not conflating them.

**Guard 1 — Idempotency (on Start).** *Problem:* a flaky network makes the client retry "start a
run," and now you've started the same job twice. *Fix:* send an `Idempotency-Key` header. The
first request to claim that key wins and gets a `runId`; any duplicate gets handed back the *same*
`runId` instead of spawning a second run. (Backed by Redis's atomic `SET key val NX EX` — one
race-free round trip — or an in-memory equivalent.)

**Guard 2 — Steer lock (on Steer).** *Problem:* two operators both try to steer the *same* run at
the same instant — one clicks Kill while the other clicks Redirect. *Fix:* a short-lived per-run
lock. Exactly one gets in; the other is told **409 Conflict** ("someone else is steering this run
right now") rather than having the two intents silently interleave. The entity already prevents
*corruption*; this lock is a level up — it rejects the second *operator* cleanly.

Different problems, different guards. Guard 1 stops duplicate *runs*; Guard 2 stops conflicting
*commands* on one run.

---

## 9. Stores: nothing required, everything swappable

Every external store follows the same pattern: **an interface, a real implementation, and an
in-memory fallback.** Which one you get is decided by whether a connection string is set — *you
never change code to switch.*

| Concern | Connection string blank (default) | Connection string set |
|---|---|---|
| Idempotency + steer lock | in-memory | **Redis** |
| Run history | in-memory | **Cosmos DB** (event-sourced, partitioned by `runId`) |

This is why the 5-minute demo needs zero infrastructure: with the strings blank in
`local.settings.json`, everything runs in memory. Set `RedisConnection` or `CosmosConnection`
(the README shows Docker one-liners for both emulators) and the real implementations light up —
no call sites change. That's the strategy pattern doing its job.

---

## 10. The one gotcha to remember

The agent loop is a **Durable orchestrator**, and orchestrators have a strict rule: their code
must be **replayable** — the runtime re-runs it from the start to rebuild state, so it has to
produce identical results every time. That means **inside the loop you must not**:

- read `DateTime.UtcNow` → use `context.CurrentUtcDateTime`
- call `Guid.NewGuid()` → pass IDs in from outside
- `Task.Delay(...)` → use `context.CreateTimer(...)`
- do any direct I/O (network, disk, database)

Anything non-deterministic — including the actual tool execution and all the Polly retry/timeout
logic — lives in **activities** (`ToolActivities.cs`), never in the loop. If you remember one
rule from this whole document, remember this one: **keep the orchestrator pure.**

---

## Where to go next

- **[Architecture](architecture.md)** — the diagrams: component map, steer sequence, run lifecycle.
- **[README](../README.md)** — full API reference, store config keys, and the "production
  hardening" notes (auth, real sandboxing, what each shortcut would become for real).
- **[CLAUDE.md](../CLAUDE.md)** — the architecture deep-dive and the determinism rules in detail.
- **The code itself** — start at `Functions/SteeringApi.cs`, then
  `Functions/AgentOrchestrator.cs`. With this tour in your head, both read straight through.
