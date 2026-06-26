using AgentSteeringService.Models;
using AgentSteeringService.Services;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace AgentSteeringService.Tests;

// Integration tests for the real Cosmos-backed history store.
//
// Opt-in: they run only when COSMOS_TEST_CONNECTION points at a reachable Cosmos
// (emulator or account). Without it every test is SKIPPED, so CI without an
// emulator stays green and fast. To run them locally:
//
//   docker run -d -p 8081:8081 mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
//   COSMOS_TEST_CONNECTION="AccountEndpoint=https://localhost:8081/;AccountKey=<key>;" dotnet test
//
// Each test uses its own runId, so they share one throwaway database without colliding.
public class CosmosRunHistoryStoreTests : IAsyncLifetime
{
    private static readonly string? Conn = Environment.GetEnvironmentVariable("COSMOS_TEST_CONNECTION");

    private readonly string _dbName = "ass_test_" + Guid.NewGuid().ToString("N");
    private CosmosClient? _client;
    private IRunHistoryStore _store = null!;

    public Task InitializeAsync()
    {
        if (string.IsNullOrWhiteSpace(Conn))
            return Task.CompletedTask; // tests will Skip before touching _store

        _client = new CosmosClient(Conn, new CosmosClientOptions
        {
            ConnectionMode = ConnectionMode.Gateway,
            LimitToEndpoint = true,
            // Emulator serves a self-signed cert; accept it in tests only.
            HttpClientFactory = () => new HttpClient(new HttpClientHandler
            {
                ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
            }),
            SerializerOptions = new CosmosSerializationOptions
            {
                PropertyNamingPolicy = CosmosPropertyNamingPolicy.CamelCase
            }
        });

        var cfg = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["CosmosDatabase"] = _dbName,
                ["CosmosContainer"] = "runhistory"
            })
            .Build();

        _store = new CosmosRunHistoryStore(_client, cfg);
        return Task.CompletedTask;
    }

    public async Task DisposeAsync()
    {
        if (_client is not null)
        {
            try { await _client.GetDatabase(_dbName).DeleteAsync(); } catch { /* best-effort cleanup */ }
            _client.Dispose();
        }
    }

    private static RunHistoryEvent Event(string runId, string type, DateTime ts) =>
        new(Guid.NewGuid().ToString(), runId, type, Detail: type, ts);

    [SkippableFact]
    public async Task Append_then_Get_round_trips_an_event()
    {
        Skip.If(string.IsNullOrWhiteSpace(Conn), "COSMOS_TEST_CONNECTION not set");
        var runId = Guid.NewGuid().ToString();

        await _store.AppendAsync(Event(runId, "START", DateTime.UtcNow));

        var events = await _store.GetAsync(runId);
        Assert.Single(events);
        Assert.Equal("START", events[0].Type);
        Assert.Equal(runId, events[0].RunId);
    }

    [SkippableFact]
    public async Task Get_returns_events_ordered_by_timestamp()
    {
        Skip.If(string.IsNullOrWhiteSpace(Conn), "COSMOS_TEST_CONNECTION not set");
        var runId = Guid.NewGuid().ToString();
        var t0 = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        // Append out of chronological order; the store must return them sorted.
        await _store.AppendAsync(Event(runId, "THIRD", t0.AddSeconds(2)));
        await _store.AppendAsync(Event(runId, "FIRST", t0));
        await _store.AppendAsync(Event(runId, "SECOND", t0.AddSeconds(1)));

        var events = await _store.GetAsync(runId);

        Assert.Equal(new[] { "FIRST", "SECOND", "THIRD" }, events.Select(e => e.Type).ToArray());
    }

    [SkippableFact]
    public async Task Get_is_scoped_to_one_run_partition()
    {
        Skip.If(string.IsNullOrWhiteSpace(Conn), "COSMOS_TEST_CONNECTION not set");
        var runA = Guid.NewGuid().ToString();
        var runB = Guid.NewGuid().ToString();

        await _store.AppendAsync(Event(runA, "A1", DateTime.UtcNow));
        await _store.AppendAsync(Event(runB, "B1", DateTime.UtcNow));

        var a = await _store.GetAsync(runA);

        Assert.Single(a);
        Assert.Equal("A1", a[0].Type);
    }
}
