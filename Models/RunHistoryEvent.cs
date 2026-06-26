namespace AgentSteeringService.Models;

// One immutable, event-sourced record of something that happened in a run.
// Stored in Cosmos partitioned by RunId; serialized camelCase (id, runId, type, ...).
public record RunHistoryEvent(
    string Id,
    string RunId,
    string Type,
    string Detail,
    DateTime TimestampUtc);
