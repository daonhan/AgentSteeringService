using System.Net;
using AgentSteeringService.Models;
using AgentSteeringService.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.DurableTask.Client;
using Microsoft.DurableTask.Entities;
using Microsoft.Extensions.Logging;

namespace AgentSteeringService.Functions;

// The CONTROL PLANE / steering API. Front door for operators and parent systems.
// In production this sits behind APIM + Entra ID (validate-jwt) — see README.
public class SteeringApi
{
    private static readonly TimeSpan IdempotencyTtl = TimeSpan.FromHours(24);

    private readonly IIdempotencyStore _idempotency;
    private readonly IRunHistoryStore _history;

    public SteeringApi(IIdempotencyStore idempotency, IRunHistoryStore history)
    {
        _idempotency = idempotency;
        _history = history;
    }

    // POST /api/runs            body: { "instruction": "summarize docs", "maxSteps": 10 }
    // Header (optional): Idempotency-Key: <guid>
    [Function("StartRun")]
    public async Task<HttpResponseData> StartRun(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "runs")] HttpRequestData req,
        [DurableClient] DurableTaskClient client)
    {
        var log = req.FunctionContext.GetLogger<SteeringApi>();
        var body = await req.ReadFromJsonAsync<StartRequest>() ?? new StartRequest("noop");

        string? idemKey = req.Headers.TryGetValues("Idempotency-Key", out var keys) ? keys.FirstOrDefault() : null;

        // Fast path: key already maps to a run -> return it, never start a duplicate.
        if (idemKey is not null && await _idempotency.GetAsync(idemKey) is { } known)
            return await Json(req, HttpStatusCode.OK, new { runId = known, idempotentReplay = true });

        var instanceId = await client.ScheduleNewOrchestrationInstanceAsync(nameof(AgentOrchestrator));

        // Atomic claim closes the race between two concurrent identical POSTs.
        if (idemKey is not null && !await _idempotency.TrySetAsync(idemKey, instanceId, IdempotencyTtl))
        {
            // We lost the claim: a concurrent request already owns this key. Adopt theirs, drop ours.
            await client.TerminateInstanceAsync(instanceId);
            var winner = await _idempotency.GetAsync(idemKey);
            return await Json(req, HttpStatusCode.OK, new { runId = winner ?? instanceId, idempotentReplay = true });
        }

        var entityId = new EntityInstanceId(nameof(AgentRunEntity), instanceId);
        await client.Entities.SignalEntityAsync(entityId, "Start", new StartArgs(body.Instruction, body.MaxSteps));
        await Record(instanceId, "START", $"instruction='{body.Instruction}' maxSteps={body.MaxSteps}");

        log.LogInformation("Started run {RunId} instruction='{Instruction}'", instanceId, body.Instruction);
        return await Json(req, HttpStatusCode.Accepted, new { runId = instanceId });
    }

    // POST /api/runs/{id}/steer  body: { "action": "Pause" | "Resume" | "Kill" | "Redirect", "newInstruction": "..." }
    [Function("SteerRun")]
    public async Task<HttpResponseData> SteerRun(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "runs/{id}/steer")] HttpRequestData req,
        string id,
        [DurableClient] DurableTaskClient client)
    {
        var log = req.FunctionContext.GetLogger<SteeringApi>();
        var cmd = await req.ReadFromJsonAsync<SteerRequest>();
        if (cmd is null)
            return await Json(req, HttpStatusCode.BadRequest, new { error = "invalid body" });

        var entityId = new EntityInstanceId(nameof(AgentRunEntity), id);

        // 1) Update authoritative control state on the entity.
        var op = cmd.Action switch
        {
            SteerAction.Pause => client.Entities.SignalEntityAsync(entityId, "Pause"),
            SteerAction.Resume => client.Entities.SignalEntityAsync(entityId, "Resume"),
            SteerAction.Kill => client.Entities.SignalEntityAsync(entityId, "Kill"),
            SteerAction.Redirect => client.Entities.SignalEntityAsync(entityId, "Redirect", cmd.NewInstruction ?? ""),
            _ => Task.CompletedTask
        };
        await op;

        // 2) Wake a paused orchestration so it re-reads state immediately.
        await client.RaiseEventAsync(id, AgentOrchestrator.SteerEventName, cmd.Action.ToString());
        await Record(id, $"STEER:{cmd.Action}", cmd.NewInstruction ?? "");

        log.LogInformation("Steer {Action} -> run {RunId}", cmd.Action, id);
        return await Json(req, HttpStatusCode.Accepted, new { runId = id, action = cmd.Action.ToString() });
    }

    // GET /api/runs/{id}  -> current state + in-entity audit trail.
    [Function("GetRun")]
    public async Task<HttpResponseData> GetRun(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "runs/{id}")] HttpRequestData req,
        string id,
        [DurableClient] DurableTaskClient client)
    {
        var entityId = new EntityInstanceId(nameof(AgentRunEntity), id);
        var entity = await client.Entities.GetEntityAsync<AgentRunState>(entityId);
        if (entity is null)
            return await Json(req, HttpStatusCode.NotFound, new { error = "run not found" });

        return await Json(req, HttpStatusCode.OK, entity.State);
    }

    // GET /api/runs/{id}/history  -> event-sourced history from the run-history store (Cosmos).
    [Function("GetRunHistory")]
    public async Task<HttpResponseData> GetRunHistory(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "runs/{id}/history")] HttpRequestData req,
        string id)
    {
        var events = await _history.GetAsync(id);
        return await Json(req, HttpStatusCode.OK, events);
    }

    private Task Record(string runId, string type, string detail)
        => _history.AppendAsync(new RunHistoryEvent(Guid.NewGuid().ToString(), runId, type, detail, DateTime.UtcNow));

    private static async Task<HttpResponseData> Json(HttpRequestData req, HttpStatusCode code, object payload)
    {
        var res = req.CreateResponse();
        await res.WriteAsJsonAsync(payload);   // defaults status to 200...
        res.StatusCode = code;                 // ...so set the intended status explicitly.
        return res;
    }
}
