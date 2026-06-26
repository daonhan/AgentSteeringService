using AgentSteeringService.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask.Entities;

namespace AgentSteeringService.Functions;

// Durable Entity = the single source of truth for one agent run's control state.
// Steering HTTP endpoints SIGNAL this entity; the orchestrator READS it each loop.
// Operations are serialized per-entity, so concurrent steering commands can't corrupt state.
public class AgentRunEntity : TaskEntity<AgentRunState>
{
    // Reference-type state must be initialized explicitly.
    protected override AgentRunState InitializeState(TaskEntityOperation operation) => new();

    public void Start(StartArgs args)
    {
        State.Status = RunStatus.Running;
        State.Instruction = args.Instruction;
        State.MaxSteps = args.MaxSteps;
        Audit($"START instruction='{args.Instruction}' maxSteps={args.MaxSteps}");
    }

    public void Pause()
    {
        if (State.Status == RunStatus.Running)
        {
            State.Status = RunStatus.Paused;
            Audit("PAUSE");
        }
    }

    public void Resume()
    {
        if (State.Status == RunStatus.Paused)
        {
            State.Status = RunStatus.Running;
            Audit("RESUME");
        }
    }

    public void Kill()
    {
        State.Status = RunStatus.Killed;
        Audit("KILL");
    }

    public void Redirect(string newInstruction)
    {
        State.Instruction = newInstruction;
        Audit($"REDIRECT -> '{newInstruction}'");
    }

    public void AdvanceStep()
    {
        State.CurrentStep++;
        Audit($"STEP {State.CurrentStep}/{State.MaxSteps}");
    }

    public void Complete()
    {
        if (State.Status is RunStatus.Running or RunStatus.Paused)
        {
            State.Status = RunStatus.Completed;
            Audit("COMPLETE");
        }
    }

    public AgentRunState Get() => State;

    private void Audit(string message) => State.AuditLog.Add(message);

    // Entry point that dispatches incoming operations to the methods above.
    [Function(nameof(AgentRunEntity))]
    public static Task RunEntityAsync([EntityTrigger] TaskEntityDispatcher dispatcher)
        => dispatcher.DispatchAsync<AgentRunEntity>();
}
