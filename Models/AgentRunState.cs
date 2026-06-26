using System.Text.Json.Serialization;

namespace AgentSteeringService.Models;

// Serialized as readable strings ("Running") instead of integers.
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum RunStatus
{
    Pending,
    Running,
    Paused,
    Killed,
    Completed
}

// Authoritative control + progress state for one agent run.
// Lives inside the Durable Entity (see AgentRunEntity).
public class AgentRunState
{
    public RunStatus Status { get; set; } = RunStatus.Pending;
    public int CurrentStep { get; set; }
    public int MaxSteps { get; set; } = 10;
    public string Instruction { get; set; } = string.Empty;

    // "audit on every action" — every state transition appends here.
    public List<string> AuditLog { get; set; } = new();
}
