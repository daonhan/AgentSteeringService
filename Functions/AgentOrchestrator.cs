using AgentSteeringService.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Entities;
using Microsoft.Extensions.Logging;

namespace AgentSteeringService.Functions;

// The long-running "agent loop". Survives host restarts because Durable Functions
// checkpoints history. The orchestrator is the EXECUTION; the entity is the CONTROL state.
public class AgentOrchestrator
{
    // External event raised by the steering API to wake a paused run promptly.
    public const string SteerEventName = "Steer";

    // Eternal orchestration: after this many steps, ContinueAsNew to truncate history
    // so a long/unbounded loop never grows its replay log without bound.
    private const int StepsPerSegment = 5;

    [Function(nameof(AgentOrchestrator))]
    public async Task RunAsync([OrchestrationTrigger] TaskOrchestrationContext context)
    {
        var runId = context.InstanceId;
        var entityId = new EntityInstanceId(nameof(AgentRunEntity), runId);
        var logger = context.CreateReplaySafeLogger<AgentOrchestrator>();

        var stepsThisSegment = 0;

        while (true)
        {
            // Read the authoritative control state from the entity each iteration.
            var state = await context.Entities.CallEntityAsync<AgentRunState>(entityId, "Get");

            // kill -> stop cleanly.
            if (state.Status == RunStatus.Killed)
            {
                logger.LogInformation("Run {RunId} KILLED at step {Step}", runId, state.CurrentStep);
                return;
            }

            // done -> mark complete and stop.
            if (state.Status == RunStatus.Completed || state.CurrentStep >= state.MaxSteps)
            {
                await context.Entities.SignalEntityAsync(entityId, "Complete");
                logger.LogInformation("Run {RunId} COMPLETED at step {Step}", runId, state.CurrentStep);
                return;
            }

            // pause -> block on an external event (cheap; no compute burned) until steered.
            if (state.Status == RunStatus.Paused)
            {
                logger.LogInformation("Run {RunId} PAUSED, awaiting steer event", runId);
                await context.WaitForExternalEvent<string>(SteerEventName);
                continue; // re-read state, then act on resume / kill / redirect
            }

            // running -> execute one tool step (redirect is picked up via state.Instruction).
            var input = new ToolStepInput(runId, state.CurrentStep + 1, state.Instruction);
            await context.CallActivityAsync<string>(nameof(ToolActivities.ExecuteToolStep), input);
            await context.Entities.SignalEntityAsync(entityId, "AdvanceStep");
            stepsThisSegment++;

            // Pace the loop with a durable timer (deterministic; never use Task.Delay here).
            await context.CreateTimer(context.CurrentUtcDateTime.AddSeconds(1), CancellationToken.None);

            // Truncate history while still Running. Safe here because we are NOT mid wait-for-event;
            // control state lives in the entity, so the fresh instance just re-reads and continues.
            if (stepsThisSegment >= StepsPerSegment)
            {
                logger.LogInformation("Run {RunId} ContinueAsNew (history reset) at step {Step}", runId, state.CurrentStep + 1);
                context.ContinueAsNew(null);
                return;
            }
        }
    }
}
