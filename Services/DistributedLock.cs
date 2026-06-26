using System.Collections.Concurrent;

namespace AgentSteeringService.Services;

// Mutual exclusion across instances for a single key (e.g. one agent run).
// Mirrors the idempotency-store shape: an interface with a Redis impl and an in-memory fallback.
// Acquire returns an opaque ownership token; release is a compare-and-delete with that token,
// so a slow releaser can never delete a lock that a later holder acquired after ours expired.
public interface IDistributedLock
{
    // Acquire 'key' for at most 'ttl'. Returns the ownership token if acquired, or null if held.
    Task<string?> TryAcquireAsync(string key, TimeSpan ttl);

    // Release 'key' only if 'token' still owns it. No-op otherwise (someone else / already expired).
    Task ReleaseAsync(string key, string token);
}

// In-memory fallback for local dev with no Redis configured.
// TryAdd gives the same atomic single-winner claim in-process; TTL is not enforced here
// (same simplification as InMemoryIdempotencyStore — the finally-release covers the normal path).
public class InMemoryDistributedLock : IDistributedLock
{
    private readonly ConcurrentDictionary<string, string> _held = new();

    public Task<string?> TryAcquireAsync(string key, TimeSpan ttl)
    {
        var token = Guid.NewGuid().ToString("N");
        return Task.FromResult(_held.TryAdd(key, token) ? token : null);
    }

    public Task ReleaseAsync(string key, string token)
    {
        // Compare-and-delete: only the current owner may release.
        if (_held.TryGetValue(key, out var current) && current == token)
            _held.TryRemove(new KeyValuePair<string, string>(key, token));
        return Task.CompletedTask;
    }
}
