using AgentSteeringService.Models;
using AgentSteeringService.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Polly;
using Polly.CircuitBreaker;
using Polly.Retry;
using Polly.Timeout;

namespace AgentSteeringService.Functions;

// Activity = the non-deterministic "outside world". This is where real tool execution
// would happen (call an LLM, run a sandboxed script, hit an external API).
// Polly lives HERE, never in the orchestrator (orchestrator code must stay deterministic).
public class ToolActivities
{
    private readonly IRunHistoryStore _history;

    public ToolActivities(IRunHistoryStore history) => _history = history;

    // Order = outermost first: Retry wraps CircuitBreaker wraps per-attempt Timeout.
    //   Retry          - ride out transient blips (exponential backoff + jitter).
    //   CircuitBreaker - stop hammering a downstream that's actually down; fail fast while open.
    //   Timeout        - bound each attempt so one hung call can't pin the activity.
    private static readonly ResiliencePipeline Pipeline = new ResiliencePipelineBuilder()
        .AddRetry(new RetryStrategyOptions
        {
            MaxRetryAttempts = 3,
            BackoffType = DelayBackoffType.Exponential,
            UseJitter = true,
            Delay = TimeSpan.FromMilliseconds(200)
        })
        .AddCircuitBreaker(new CircuitBreakerStrategyOptions
        {
            FailureRatio = 0.5,                          // open when >=50% of...
            MinimumThroughput = 4,                       // ...at least 4 calls...
            SamplingDuration = TimeSpan.FromSeconds(30), // ...within this window fail.
            BreakDuration = TimeSpan.FromSeconds(15)     // stay open this long, then half-open.
        })
        .AddTimeout(new TimeoutStrategyOptions { Timeout = TimeSpan.FromSeconds(10) })
        .Build();

    [Function(nameof(ExecuteToolStep))]
    public async Task<string> ExecuteToolStep([ActivityTrigger] ToolStepInput input, FunctionContext ctx)
    {
        var log = ctx.GetLogger<ToolActivities>();

        var result = await Pipeline.ExecuteAsync(async _ =>
        {
            log.LogInformation(
                "Tool step {Step} run={RunId} instruction='{Instruction}'",
                input.Step, input.RunId, input.Instruction);

            // Simulated work — replace with sandboxed tool execution.
            await Task.Delay(50);
            return $"step {input.Step} done: {input.Instruction}";
        });

        // Event-source the step into the run-history store (Cosmos, partitioned by runId).
        await _history.AppendAsync(new RunHistoryEvent(
            Guid.NewGuid().ToString(), input.RunId, "STEP", result, DateTime.UtcNow));

        return result;
    }
}
