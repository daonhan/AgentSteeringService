using System.Collections.Concurrent;

namespace AgentSteeringService.Services;

public interface IIdempotencyStore
{
    // Existing run id for this key, or null if never claimed.
    Task<string?> GetAsync(string key);

    // Atomic create-if-absent with TTL. Returns true only if THIS caller won the claim.
    Task<bool> TrySetAsync(string key, string value, TimeSpan ttl);
}

// In-memory fallback for local dev with no Redis configured.
// TryAdd gives the same atomic claim semantics single-process; TTL is ignored here.
public class InMemoryIdempotencyStore : IIdempotencyStore
{
    private readonly ConcurrentDictionary<string, string> _store = new();

    public Task<string?> GetAsync(string key)
        => Task.FromResult(_store.TryGetValue(key, out var v) ? v : null);

    public Task<bool> TrySetAsync(string key, string value, TimeSpan ttl)
        => Task.FromResult(_store.TryAdd(key, value));
}
