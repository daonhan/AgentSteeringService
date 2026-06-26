using AgentSteeringService.Services;
using Xunit;

namespace AgentSteeringService.Tests;

public class DistributedLockTests
{
    private static readonly TimeSpan Ttl = TimeSpan.FromSeconds(30);

    [Fact]
    public async Task Acquire_on_a_free_key_returns_a_token()
    {
        IDistributedLock locks = new InMemoryDistributedLock();

        var token = await locks.TryAcquireAsync("steer:run-1", Ttl);

        Assert.False(string.IsNullOrEmpty(token));
    }

    [Fact]
    public async Task Second_acquire_while_held_is_refused()
    {
        IDistributedLock locks = new InMemoryDistributedLock();

        var first = await locks.TryAcquireAsync("steer:run-1", Ttl);
        var second = await locks.TryAcquireAsync("steer:run-1", Ttl);

        Assert.NotNull(first);
        Assert.Null(second); // contention on the same run -> caller should 409
    }

    [Fact]
    public async Task Release_lets_the_key_be_reacquired()
    {
        IDistributedLock locks = new InMemoryDistributedLock();

        var first = await locks.TryAcquireAsync("steer:run-1", Ttl);
        await locks.ReleaseAsync("steer:run-1", first!);
        var second = await locks.TryAcquireAsync("steer:run-1", Ttl);

        Assert.NotNull(second);
    }

    [Fact]
    public async Task Release_with_a_foreign_token_does_not_free_the_lock()
    {
        IDistributedLock locks = new InMemoryDistributedLock();

        var owner = await locks.TryAcquireAsync("steer:run-1", Ttl);
        await locks.ReleaseAsync("steer:run-1", "not-the-owners-token");

        // Owner's lock must survive a foreign release attempt.
        Assert.Null(await locks.TryAcquireAsync("steer:run-1", Ttl));
        Assert.NotNull(owner);
    }

    [Fact]
    public async Task Different_keys_are_independent()
    {
        IDistributedLock locks = new InMemoryDistributedLock();

        var a = await locks.TryAcquireAsync("steer:run-1", Ttl);
        var b = await locks.TryAcquireAsync("steer:run-2", Ttl);

        Assert.NotNull(a);
        Assert.NotNull(b);
    }
}
