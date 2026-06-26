using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Middleware;
using Microsoft.Extensions.Logging;

namespace AgentSteeringService.Middleware;

// Cross-cutting "audit/telemetry on every action". Wraps every function invocation.
// In production: enrich with correlation IDs, the caller's Entra object id, and push to App Insights.
public class TelemetryMiddleware : IFunctionsWorkerMiddleware
{
    public async Task Invoke(FunctionContext context, FunctionExecutionDelegate next)
    {
        var log = context.GetLogger<TelemetryMiddleware>();
        var name = context.FunctionDefinition.Name;

        log.LogInformation("-> {Function} invocation={Id}", name, context.InvocationId);
        try
        {
            await next(context);
            log.LogInformation("<- {Function} ok", name);
        }
        catch (Exception ex)
        {
            log.LogError(ex, "<- {Function} FAILED", name);
            throw;
        }
    }
}
