using StackExchange.Redis;

namespace AgentSteeringService.Services;

// Cross-instance lock backed by Redis.
// Acquire is a single atomic command: SET key token NX EX <ttl> — NX = only if absent (the lock),
// EX = auto-expire (a crashed holder can't wedge the run forever).
// Release runs a Lua script so the get-and-delete is atomic: it deletes ONLY if the stored value is
// still our token, so we never free a lock a later holder took after ours had expired.
public class RedisDistributedLock : IDistributedLock
{
    private readonly IDatabase _db;

    public RedisDistributedLock(IConnectionMultiplexer mux) => _db = mux.GetDatabase();

    public async Task<string?> TryAcquireAsync(string key, TimeSpan ttl)
    {
        var token = Guid.NewGuid().ToString("N");
        var won = await _db.StringSetAsync(Prefixed(key), token, ttl, When.NotExists);
        return won ? token : null;
    }

    private const string ReleaseScript =
        "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end";

    public Task ReleaseAsync(string key, string token)
        => _db.ScriptEvaluateAsync(ReleaseScript, new RedisKey[] { Prefixed(key) }, new RedisValue[] { token });

    private static RedisKey Prefixed(string key) => $"lock:{key}";
}
