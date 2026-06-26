using System.Collections.Concurrent;
using AgentSteeringService.Models;

namespace AgentSteeringService.Services;

// Append-only, event-sourced history of a run. "store agent execution history" from the JD.
public interface IRunHistoryStore
{
    Task AppendAsync(RunHistoryEvent e);
    Task<IReadOnlyList<RunHistoryEvent>> GetAsync(string runId);
}

// In-memory fallback for local dev with no Cosmos configured.
public class InMemoryRunHistoryStore : IRunHistoryStore
{
    private readonly ConcurrentDictionary<string, List<RunHistoryEvent>> _byRun = new();

    public Task AppendAsync(RunHistoryEvent e)
    {
        var list = _byRun.GetOrAdd(e.RunId, _ => new List<RunHistoryEvent>());
        lock (list) list.Add(e);
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<RunHistoryEvent>> GetAsync(string runId)
    {
        if (!_byRun.TryGetValue(runId, out var list))
            return Task.FromResult<IReadOnlyList<RunHistoryEvent>>(Array.Empty<RunHistoryEvent>());
        lock (list)
            return Task.FromResult<IReadOnlyList<RunHistoryEvent>>(
                list.OrderBy(e => e.TimestampUtc).ToList());
    }
}
