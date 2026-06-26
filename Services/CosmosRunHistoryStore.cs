using AgentSteeringService.Models;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Configuration;

namespace AgentSteeringService.Services;

// Cosmos-backed run history.
// Partition key = /runId -> every read/write for one run hits a single logical partition,
// so AppendAsync is a cheap point-write and GetAsync is a single-partition query (low RU).
public class CosmosRunHistoryStore : IRunHistoryStore
{
    private readonly CosmosClient _client;
    private readonly string _dbName;
    private readonly string _containerName;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private Container? _container;

    public CosmosRunHistoryStore(CosmosClient client, IConfiguration cfg)
    {
        _client = client;
        _dbName = cfg["CosmosDatabase"] ?? "agentsteering";
        _containerName = cfg["CosmosContainer"] ?? "runhistory";
    }

    // Create db/container on first use (handy for the emulator; pre-provision in real envs).
    private async Task<Container> ContainerAsync()
    {
        if (_container is not null) return _container;
        await _gate.WaitAsync();
        try
        {
            if (_container is null)
            {
                var db = await _client.CreateDatabaseIfNotExistsAsync(_dbName);
                var c = await db.Database.CreateContainerIfNotExistsAsync(
                    new ContainerProperties(_containerName, partitionKeyPath: "/runId"),
                    throughput: 400);
                _container = c.Container;
            }
        }
        finally { _gate.Release(); }
        return _container;
    }

    public async Task AppendAsync(RunHistoryEvent e)
    {
        var container = await ContainerAsync();
        await container.CreateItemAsync(e, new PartitionKey(e.RunId));
    }

    public async Task<IReadOnlyList<RunHistoryEvent>> GetAsync(string runId)
    {
        var container = await ContainerAsync();
        var query = new QueryDefinition("SELECT * FROM c WHERE c.runId = @r ORDER BY c.timestampUtc")
            .WithParameter("@r", runId);

        var iterator = container.GetItemQueryIterator<RunHistoryEvent>(
            query,
            requestOptions: new QueryRequestOptions { PartitionKey = new PartitionKey(runId) });

        var results = new List<RunHistoryEvent>();
        while (iterator.HasMoreResults)
            results.AddRange(await iterator.ReadNextAsync());
        return results;
    }
}
