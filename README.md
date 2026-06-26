# Agent Steering Service

[![CI](https://github.com/daonhan/AgentSteeringService/actions/workflows/ci.yml/badge.svg)](https://github.com/daonhan/AgentSteeringService/actions/workflows/ci.yml)
[![.NET](https://img.shields.io/badge/.NET-8.0-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![Azure Functions](https://img.shields.io/badge/Azure%20Functions-v4%20isolated-0062AD?logo=azurefunctions&logoColor=white)](https://learn.microsoft.com/azure/azure-functions/dotnet-isolated-process-guide)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

The **control plane** for an AI-agent runtime: it starts long-running agent loops and
**steers them in flight** — pause / resume / kill / redirect.

Built on **.NET 8 · Azure Functions (isolated worker) HTTP (`HttpRequestData`) · Durable
Functions · Polly · Application Insights**.

> Learning scaffold, not production. It runs locally and demonstrates the patterns; the
> "Production hardening" section maps each shortcut to what you'd really do.

---

## What's implemented

| Capability | Where it lives in this repo |
|---|---|
| steering API: **pause/resume/kill/override/redirect** | `Functions/SteeringApi.cs` → entity signals + external event |
| **Durable orchestrations for long-running agent loops** | `Functions/AgentOrchestrator.cs` (the agent loop) |
| run state that survives restarts | `Functions/AgentRunEntity.cs` (Durable **Entity** = source of truth) |
| **tool-execution sandbox plumbing** | `Functions/ToolActivities.cs` (activity = isolated outside world) |
| **idempotency** | `Idempotency-Key` header → Redis atomic `SET NX EX` (`RedisIdempotencyStore`), in-memory fallback |
| **no two operators steer one run at once** | Redis distributed lock per run (`IDistributedLock`/`RedisDistributedLock`) → second concurrent `/steer` gets **409** |
| **retries / circuit-breakers** | Polly `ResiliencePipeline` (retry + circuit breaker + timeout) in `ToolActivities.cs` |
| unbounded loop, bounded history | `ContinueAsNew` (eternal orchestration) in `AgentOrchestrator.cs` |
| event-sourced run history | `CosmosRunHistoryStore` (partition `/runId`), in-memory fallback |
| **audit/telemetry on every action** | `Middleware/TelemetryMiddleware.cs` + `AuditLog` on the entity |
| Azure Functions **isolated worker** | `Program.cs` (`HostBuilder`, `dotnet-isolated`) |

---

## The steering mechanism (the part to understand cold)

Two Durable building blocks work together:

- **Durable Entity (`AgentRunEntity`)** — the authoritative *control state* (`Running/Paused/Killed/...`,
  current step, instruction). Operations are serialized per entity, so two concurrent steering
  commands can't corrupt it. Steering endpoints **signal** the entity.
- **Orchestrator (`AgentOrchestrator`)** — the *execution*. Each loop iteration it reads the entity
  and obeys it. When `Paused`, it parks on `WaitForExternalEvent("Steer")` — burning no compute —
  until the steering API **raises that event** to wake it.

```
operator ──POST /runs/{id}/steer──► SteeringApi
                                      ├─ signal entity   (update control state)
                                      └─ raise "Steer"    (wake a paused orchestrator)
                                                 │
AgentOrchestrator loop: read entity ─► switch(status) ─► Running: run tool step → advance
                                                          Paused : await external event
                                                          Killed : stop
```

**Determinism rule** (the classic Durable gotcha): orchestrator code must replay identically —
no `DateTime.UtcNow` (use `context.CurrentUtcDateTime`), no `Guid.NewGuid()`, no direct I/O.
All of that lives in **activities** (`ToolActivities`), which is also why Polly sits there, not in the loop.

---

## API

| Method | Route | Purpose |
|---|---|---|
| `POST` | `/api/runs` | Start a run. Body `{ "instruction": "...", "maxSteps": 10 }`. Optional `Idempotency-Key` header. |
| `POST` | `/api/runs/{id}/steer` | Body `{ "action": "Pause\|Resume\|Kill\|Redirect", "newInstruction": "..." }`. Returns **409** if another operator is mid-steer on the same run. |
| `GET`  | `/api/runs/{id}` | Current state + in-entity audit trail. |
| `GET`  | `/api/runs/{id}/history` | Event-sourced history from the run-history store (Cosmos). |

---

## Run it locally

Prereqs: **.NET 8 SDK** (or any newer SDK that can target `net8.0`), **Azure Functions Core Tools v4**, **Azurite**.

```bash
# one-time installs
npm install -g azure-functions-core-tools@4   # the `func` host  (or: winget install Microsoft.Azure.FunctionsCoreTools)
npm install -g azurite                         # local storage emulator Durable needs
```

Then, from this folder:

```bash
# 0) create your local settings from the template
cp local.settings.json.example local.settings.json

# 1) storage emulator (own terminal)
azurite

# 2) build + run the Functions host (own terminal)
func start

# 3) drive the demo (own terminal)
pwsh ./demo.ps1          # or step through demo.http in VS Code REST Client
```

Expected: the run advances a step/second, **pauses** on command, keeps its **redirected**
instruction after **resume**, and stops on **kill** — with the whole story in the `auditLog`.

---

## Stores: Redis + Cosmos

Both are **optional**. With the connection strings blank in `local.settings.json` the app uses
in-memory fallbacks and runs with zero external infra. Set a connection string to switch the
real implementation on — no code change.

| Setting | Empty (default) | Set |
|---|---|---|
| `RedisConnection` | in-memory idempotency + steer lock | `RedisIdempotencyStore` (`SET NX EX`) + `RedisDistributedLock` (`SET NX EX` + Lua compare-and-delete release) |
| `CosmosConnection` | in-memory history | `CosmosRunHistoryStore` — db/container auto-created, partition `/runId` |
| `CosmosDatabase` / `CosmosContainer` | `agentsteering` / `runhistory` | override names |

Run the emulators locally:

```bash
# Redis  (Docker)
docker run -d -p 6379:6379 redis
#   -> RedisConnection = localhost:6379

# Cosmos DB emulator (Docker; Linux vNext emulator)
docker run -d -p 8081:8081 mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
#   -> CosmosConnection = AccountEndpoint=http://localhost:8081/;AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;
```

The vNext emulator serves **plain HTTP** on `8081` (no cert to trust) and accepts the well-known
account key above. Client is in **Gateway** mode for emulator friendliness.

With the emulator up, the Cosmos store's integration tests (append → ordered single-partition read →
partition isolation) run against it; without `COSMOS_TEST_CONNECTION` set they skip, so CI stays fast:

```bash
COSMOS_TEST_CONNECTION="AccountEndpoint=http://localhost:8081/;AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;" \
  dotnet test tests/AgentSteeringService.Tests/AgentSteeringService.Tests.csproj
```

Then drive the demo and read the event-sourced trail:

```bash
curl http://localhost:7071/api/runs/<runId>/history
```

**Why these stores:** Redis idempotency is a single atomic command — `SET key val NX EX` —
so the dedupe and the TTL cleanup are one race-free round trip; no read-then-write window. Cosmos
history is partitioned by `runId`, so every write is a point-write and every read is a single-partition
query (cheap, predictable RU) instead of a fan-out cross-partition scan.

---

## Production hardening

- **Auth:** front with **APIM** (`validate-jwt`) + **Entra ID**. Service-to-service = client-credentials
  flow; data stores via **Managed Identity**, no connection strings. Drop the function-key auth used here.
- **Idempotency race window:** this scaffold schedules-then-claims and terminates the loser; production
  would claim an `in-progress` marker *before* scheduling, then swap in the runId. Same idea, tighter window.
- **Bulkhead:** add rate limiter / concurrency isolation to the Polly pipeline so one bad tool can't starve the pool.
- **Real sandbox:** run tools in **Azure Container Apps / Container Instances**, reached over **gRPC** —
  compute isolation + security boundary instead of the in-proc stub here.
- **State stores:** Cosmos run history and a **Redis distributed lock** (`SET NX EX` + Lua compare-and-delete
  release, in `RedisDistributedLock`) are wired here — the lock makes `/steer` reject a second operator on the
  same run with **409** instead of interleaving intents. Still to add: **Postgres** for relational/transactional
  config + audit.
- **Telemetry:** correlation IDs end-to-end, App Insights / OpenTelemetry, caller identity on every audit line.

---

## Layout

```
AgentSteeringService/
├─ AgentSteeringService.csproj     # net8.0 isolated worker project
├─ AgentSteeringService.sln        # solution entry point
├─ Program.cs                      # isolated worker host + DI + middleware
├─ host.json                       # Functions + Durable config
├─ local.settings.json.example     # copy to local.settings.json (gitignored)
├─ global.json                     # pins the SDK band
├─ Models/
│  ├─ AgentRunState.cs             # run status + step + audit log
│  ├─ Contracts.cs                 # request/operation/activity DTOs
│  └─ RunHistoryEvent.cs           # event-sourced history record
├─ Functions/
│  ├─ SteeringApi.cs               # HTTP control plane (start / steer / get / history)
│  ├─ AgentOrchestrator.cs         # the long-running agent loop + ContinueAsNew
│  ├─ AgentRunEntity.cs            # Durable Entity — control state + audit
│  └─ ToolActivities.cs            # activity + Polly resilience (the "sandbox")
├─ Middleware/TelemetryMiddleware.cs
├─ Services/
│  ├─ IdempotencyStore.cs          # interface + in-memory
│  ├─ RedisIdempotencyStore.cs     # atomic SET NX EX
│  ├─ DistributedLock.cs           # IDistributedLock interface + in-memory fallback
│  ├─ RedisDistributedLock.cs      # SET NX EX + Lua compare-and-delete release
│  ├─ RunHistoryStore.cs           # interface + in-memory
│  └─ CosmosRunHistoryStore.cs     # event-sourced, partition /runId
├─ tests/AgentSteeringService.Tests # xUnit — distributed-lock semantics
├─ demo.http / demo.ps1            # drive the steering flow
├─ .github/workflows/ci.yml        # restore + build + format check + test
└─ README.md
```

> Package versions in the `.csproj` are pinned and verified to restore and build with 0 warnings.
> To move to newer SDKs, bump the `Microsoft.Azure.Functions.Worker.*` and `DurableTask` packages together.

## License

MIT — see [LICENSE](LICENSE).
