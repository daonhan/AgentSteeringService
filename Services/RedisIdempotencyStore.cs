using StackExchange.Redis;

namespace AgentSteeringService.Services;

// Cross-instance idempotency backed by Redis.
// The claim is a single atomic command: SET key value NX EX <ttl>.
// NX = only if absent (the dedupe), EX = auto-expire (no manual cleanup).
public class RedisIdempotencyStore : IIdempotencyStore
{
    private readonly IDatabase _db;

    public RedisIdempotencyStore(IConnectionMultiplexer mux) => _db = mux.GetDatabase();

    public async Task<string?> GetAsync(string key)
    {
        var v = await _db.StringGetAsync(Prefixed(key));
        return v.IsNullOrEmpty ? null : v.ToString();
    }

    public async Task<bool> TrySetAsync(string key, string value, TimeSpan ttl)
        => await _db.StringSetAsync(Prefixed(key), value, ttl, When.NotExists);

    private static RedisKey Prefixed(string key) => $"idem:{key}";
}
