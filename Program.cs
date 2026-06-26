using AgentSteeringService.Middleware;
using AgentSteeringService.Services;
using Microsoft.Azure.Cosmos;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using StackExchange.Redis;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults(builder =>
    {
        // "Emit audit/telemetry on every action" -> cross-cutting middleware.
        builder.UseMiddleware<TelemetryMiddleware>();
    })
    .ConfigureServices((context, services) =>
    {
        var cfg = context.Configuration;

        // --- Idempotency store: Redis if configured, else in-memory ---
        var redis = cfg["RedisConnection"];
        if (!string.IsNullOrWhiteSpace(redis))
        {
            services.AddSingleton<IConnectionMultiplexer>(ConnectionMultiplexer.Connect(redis));
            services.AddSingleton<IIdempotencyStore, RedisIdempotencyStore>();
            services.AddSingleton<IDistributedLock, RedisDistributedLock>();
        }
        else
        {
            services.AddSingleton<IIdempotencyStore, InMemoryIdempotencyStore>();
            services.AddSingleton<IDistributedLock, InMemoryDistributedLock>();
        }

        // --- Run-history store: Cosmos if configured, else in-memory ---
        var cosmos = cfg["CosmosConnection"];
        if (!string.IsNullOrWhiteSpace(cosmos))
        {
            services.AddSingleton(_ => new CosmosClient(cosmos, new CosmosClientOptions
            {
                // Gateway mode is the friendliest with the local Cosmos emulator.
                ConnectionMode = ConnectionMode.Gateway,
                SerializerOptions = new CosmosSerializationOptions
                {
                    PropertyNamingPolicy = CosmosPropertyNamingPolicy.CamelCase
                }
            }));
            services.AddSingleton<IRunHistoryStore, CosmosRunHistoryStore>();
        }
        else
        {
            services.AddSingleton<IRunHistoryStore, InMemoryRunHistoryStore>();
        }

        services.AddApplicationInsightsTelemetryWorkerService();
        services.ConfigureFunctionsApplicationInsights();
    })
    .Build();

host.Run();
