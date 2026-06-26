using System.Text.Json.Serialization;

namespace AgentSteeringService.Models;

// ----- HTTP request bodies -----

public record StartRequest(string Instruction, int MaxSteps = 10);

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum SteerAction
{
    Pause,
    Resume,
    Kill,
    Redirect
}

public record SteerRequest(SteerAction Action, string? NewInstruction = null);

// ----- Entity operation input -----

public record StartArgs(string Instruction, int MaxSteps);

// ----- Activity input -----

public record ToolStepInput(string RunId, int Step, string Instruction);
