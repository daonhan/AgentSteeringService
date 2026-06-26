# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Control plane for an AI-agent runtime, built on **Azure Functions (.NET 8, isolated worker) + Durable Functions**. It starts long-running agent loops and **steers them in flight** (pause / resume / kill / redirect). A learning scaffold — runs locally, not production-hardened. The README maps each feature to a job description and lists the production shortcuts taken.

## Commands

```bash
# Build (CI runs Release; format check below assumes a successful restore/build first)
dotnet build AgentSteeringService.csproj -c Release

# Format — CI GATE. Must pass with no changes or the build fails.
dotnet format AgentSteeringService.csproj --verify-no-changes   # check
dotnet format AgentSteeringService.csproj                        # auto-fix

# Test
dotnet test tests/AgentSteeringService.Tests/AgentSteeringService.Tests.csproj -c Release

# Single test class / method (xUnit)
dotnet test tests/AgentSteeringService.Tests/AgentSteeringService.Tests.csproj --filter "FullyQualifiedName~DistributedLockTests"
dotnet test tests/AgentSteeringService.Tests/AgentSteeringService.Tests.csproj --filter "Name=Second_acquire_while_held_is_refused"

# Run the Functions host locally (needs Azurite running + local.settings.json present)
func start          # then: pwsh ./demo.ps1   (or step through demo.http)
```

Local run prereqs: **.NET 8 SDK**, **Azure Functions Core Tools v4** (`func`), **Azurite** (Durable needs storage). Durable also requires `AzureWebJobsStorage` (set to `UseDevelopmentStorage=true` in `local.settings.json` for Azurite).

## Architecture — the one mental model to hold

**Control state and execution are split across two Durable building blocks. Internalize this before changing any Function.**

```
operator ──POST /runs/{id}/steer──► SteeringApi (HTTP, control plane)
                                      ├─ SignalEntity   → AgentRunEntity   (update control state)
                                      └─ RaiseEvent "Steer" → AgentOrchestrator (wake if paused)

AgentOrchestrator loop: read entity ─► switch(Status): Running → run tool step → advance
                                                        Paused  → await "Steer" event (no compute)
                                                        Killed  → stop
```

- **`AgentRunEntity` (Durable Entity)** = authoritative *control state* (`Status`, `CurrentStep`, `Instruction`, `AuditLog`). Operations are serialized per entity, so concurrent steering commands can't corrupt it. Steering endpoints only ever *signal* this entity.
- **`AgentOrchestrator` (orchestrator)** = the *execution*. Each loop iteration it re-reads the entity and obeys. Paused → parks on `WaitForExternalEvent("Steer")`. The steering API raises that event to wake it promptly.
- **`SteeringApi`** = the HTTP front door (start / steer / get / history). Routes are under `/api/...` (Functions host prefix). `AuthorizationLevel.Function`.
- **`ToolActivities`** = the non-deterministic "outside world" (where real tool execution would go). **Polly resilience (retry → circuit breaker → timeout) lives here**, never in the orchestrator.

### Durable determinism rules (the classic gotcha)

Orchestrator code must replay identically. **Inside `AgentOrchestrator` do NOT use**: `DateTime.UtcNow` (use `context.CurrentUtcDateTime`), `Guid.NewGuid()`, `Task.Delay` (use `context.CreateTimer`), or any direct I/O. All non-determinism belongs in activities. `ContinueAsNew` truncates replay history every `StepsPerSegment` (5) steps — safe only because control state lives in the entity, so a fresh instance just re-reads and continues. Don't `ContinueAsNew` mid `WaitForExternalEvent`.

## Stores — strategy pattern with in-memory fallbacks

Each external store is an **interface + real impl + in-memory fallback**. `Program.cs` picks the impl by whether a connection string is set in config — blank string ⇒ in-memory, zero external infra. **To switch implementations, set/clear the connection string; do not change call sites.** Keep this shape when adding a store.

| Concern | Interface | Real impl (connection set) | Fallback (blank) |
|---|---|---|---|
| Idempotency (`Idempotency-Key`) | `IIdempotencyStore` | `RedisIdempotencyStore` (`SET NX EX`) | `InMemoryIdempotencyStore` |
| Per-run steer lock | `IDistributedLock` | `RedisDistributedLock` (`SET NX EX` + Lua compare-and-delete release) | `InMemoryDistributedLock` |
| Run history (event-sourced) | `IRunHistoryStore` | `CosmosRunHistoryStore` (partition `/runId`) | `InMemoryRunHistoryStore` |

Config keys: `RedisConnection`, `CosmosConnection`, `CosmosDatabase` (default `agentsteering`), `CosmosContainer` (default `runhistory`).

### Two distinct concurrency guards (don't conflate them)

- **Idempotency** (`StartRun`): schedule orchestration → atomic claim of the key → if the claim is lost, terminate our instance and adopt the winner's runId. Closes the duplicate-POST race.
- **Distributed lock** (`SteerRun`): `TryAcquireAsync("steer:{id}")`; if held, return **409**. Stops two operators steering the *same* run at once (e.g. Kill racing Redirect). The entity already serializes state; this guard is a level up — it rejects the second operator instead of silently interleaving intents.

Cosmos uses partition key `/runId`: every write is a point-write and every read a single-partition query (low, predictable RU).

## Conventions (enforced — CI fails otherwise)

- **File-scoped namespaces**, `using` directives **outside** the namespace, **System usings first** (`.editorconfig`, warning-level).
- `Nullable` and `ImplicitUsings` enabled. DTOs are `record`s (`Models/Contracts.cs`); enums use `[JsonConverter(typeof(JsonStringEnumConverter))]`.
- **Build with 0 warnings and `dotnet format --verify-no-changes` clean** — both are CI gates.
- Package versions in `.csproj` are pinned and verified to restore/build clean. When upgrading, bump `Microsoft.Azure.Functions.Worker.*` and the `DurableTask` extension **together**.

## Project layout notes

- Single app project `AgentSteeringService.csproj` (`OutputType=Exe`, isolated worker). The test project lives under the app root, so the app `.csproj` explicitly excludes `tests/**/*.cs` from its compile — keep that exclusion if adding files.
- `AgentSteeringService.sln` is the solution entry point. `global.json` pins the SDK to 8.0.0 band (`rollForward: latestMajor`).
- **Cosmos integration tests are opt-in**: `CosmosRunHistoryStoreTests` run only when `COSMOS_TEST_CONNECTION` is set (points at the Cosmos emulator or an account); otherwise every test in it `Skip`s, so CI stays fast without an emulator. The lock tests (`DistributedLockTests`) always run against the in-memory impl.
