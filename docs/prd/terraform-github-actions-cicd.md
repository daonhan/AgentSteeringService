# PRD: Terraform + GitHub Actions CI/CD for Agent Steering Service

> Status: Draft · Owner: daonhan · Target branch: `feature/terraform`
> Scope: Infrastructure-as-Code (Terraform) provisioning Azure resources for this
> Functions app, plus a multi-environment GitHub Actions deployment pipeline.

## Problem Statement

The Agent Steering Service currently has continuous *integration* only: `ci.yml`
restores, builds, format-checks, and tests the .NET project on every PR and on pushes
to `main`. There is no continuous *delivery* — nothing provisions the Azure resources
the app needs (Function App, Storage, Application Insights, and the optional Redis +
Cosmos stores), and nothing deploys the compiled Functions app to Azure. Standing up an
environment is a manual, undocumented, click-through process that cannot be reviewed,
versioned, reproduced, or safely promoted from dev to prod. As the operator, I want the
infrastructure described as code and the deployment automated and gated, so that an
environment can be created and updated reproducibly, reviewed in a pull request, and
promoted to production only after explicit approval.

## Solution

Add Terraform that defines the full Azure footprint for two environments (dev and prod)
inside a single subscription, separated by resource group, and add a single GitHub
Actions delivery workflow (`cd.yml`) that plans on pull requests and applies +
deploys on merge to `main`, with a required-reviewer approval gate before production.

The design deliberately showcases the codebase's existing **strategy-pattern + blank
connection-string fallback**: dev provisions only the baseline (Function App + Storage +
Application Insights) and leaves `RedisConnection` / `CosmosConnection` blank so the app
runs on its in-memory fallbacks for free, while prod additionally provisions real Azure
Cache for Redis and Cosmos DB and supplies their connection strings — proving the
documented "set/clear the connection string to switch implementations" behavior across
environments without any call-site changes.

Hosting uses the modern **Flex Consumption** plan (scale-to-zero, the current
Microsoft-recommended plan for new Functions apps; Durable Functions is GA-supported on
it). Secrets reach prod via **Key Vault references** resolved by the Functions host
through the app's system-assigned managed identity, so no raw secret is ever written into
plain app settings and the application code is unchanged. Terraform state lives in an
**azurerm remote backend** bootstrapped once by a small local-state Terraform config.

## User Stories

1. As the operator, I want every Azure resource the app depends on described in
   Terraform, so that infrastructure is versioned, reviewable, and reproducible instead
   of click-through.
2. As the operator, I want a single subscription split into `rg-agentsteering-dev` and
   `rg-agentsteering-prod`, so that dev and prod are isolated with the cheapest real
   blast-radius boundary.
3. As the operator, I want a one-time, locally run bootstrap that creates the Terraform
   state storage, so that the remote backend exists before any pipeline run and I avoid
   a chicken-and-egg problem.
4. As the operator, I want the bootstrap to run with my own `az login` credentials rather
   than the CI service principal, so that the state-backend creation is decoupled from
   the deploy identity.
5. As the operator, I want the main Terraform expressed as one root module wrapping a
   reusable `modules/` directory with per-environment `*.tfvars` and per-environment
   backend keys, so that env differences are explicit and I cannot accidentally apply to
   the wrong environment.
6. As the operator, I want dev to provision only Function App + Storage + Application
   Insights, so that dev costs nothing for Redis and exercises the in-memory fallbacks.
7. As the operator, I want prod to additionally provision Azure Cache for Redis (Basic
   C0) and a serverless Cosmos DB account, so that prod exercises the real idempotency,
   distributed-lock, and run-history paths.
8. As the operator, I want the Cosmos container created with partition key `/runId`, so
   that it matches the application's documented data model and stays a single-partition,
   low-RU access pattern.
9. As the operator, I want the Function App to run on the Flex Consumption plan with the
   `dotnet-isolated` 8.0 runtime, so that I get scale-to-zero and a modern,
   Microsoft-recommended hosting model that supports Durable Functions.
10. As the operator, I want Durable Functions' required Storage account provisioned and
    wired as `AzureWebJobsStorage` plus the Flex Consumption deployment container, so that
    orchestrations and entities have their backing store.
11. As the operator, I want Application Insights (workspace-based, backed by Log
    Analytics) provisioned and its connection string set on the Function App, so that the
    telemetry middleware already wired in `Program.cs` reports in the cloud.
12. As the operator, I want prod's Redis and Cosmos secrets stored in Key Vault and
    referenced from app settings via `@Microsoft.KeyVault(...)`, so that no raw secret
    sits in plain app configuration.
13. As the operator, I want the Function App to use a system-assigned managed identity
    granted the Key Vault Secrets User role, so that it can resolve Key Vault references
    without a stored credential.
14. As the operator, I want the application code to remain unchanged, so that adding
    CI/CD does not risk regressions in the steering logic.
15. As the operator, I want GitHub Actions to authenticate to Azure with a service
    principal credential stored as the `AZURE_CREDENTIALS` GitHub secret, so that setup is
    simple and the same identity drives both `azure/login` and the azurerm provider.
16. As the operator, I want the existing `ci.yml` (build / format / test) to keep running
    on pull requests unchanged, so that fast code feedback is preserved.
17. As the operator, I want a single `cd.yml` workflow whose jobs form a clear linear DAG,
    so that the whole delivery flow lives in one reviewable file.
18. As the operator, I want pull requests to run `terraform fmt -check` and
    `terraform validate` as hard gates, so that IaC quality is enforced the same way
    `dotnet format` already is.
19. As the operator, I want pull requests to run `terraform plan` for dev and post the
    plan as a PR comment, so that infrastructure changes are reviewable before merge.
20. As the operator, I want a Checkov security scan to run on PRs and report findings as a
    comment without blocking initially, so that misconfigurations surface without a single
    opinionated rule wedging the pipeline.
21. As the operator, I want merge to `main` to apply dev and deploy the dev app
    automatically, so that the dev environment always reflects `main`.
22. As the operator, I want production apply + deploy gated behind a GitHub Environment
    (`prod`) with me as a required reviewer, so that nothing reaches prod without explicit
    human approval.
23. As the operator, I want each apply to run `terraform plan -out=tfplan`, upload the
    plan artifact, and (for prod, after approval) `terraform apply tfplan`, so that the
    plan I approved is exactly the plan that runs.
24. As the operator, I want the Function App deployed via `dotnet publish` →
    `Azure/functions-action`, with the app name and resource group flowing from the
    apply job's Terraform outputs, so that deploy targets the resources Terraform just
    created.
25. As the operator, I want `workflow_dispatch` on `cd.yml`, so that I can trigger a run
    manually without pushing a commit.
26. As the operator, I want Terraform and the azurerm provider version-pinned with a
    committed `.terraform.lock.hcl`, so that runs are deterministic across machines and CI.
27. As the operator, I want `.terraform/`, `*.tfstate*`, `tfplan`, and bootstrap local
    state git-ignored, so that no state file or plan containing secret material is ever
    committed.
28. As the operator, I want documentation describing the one-time bootstrap and the
    one-time GitHub/Azure setup (service principal, secret, Environments), so that another
    person can stand the pipeline up from scratch.
29. As a reviewer, I want to read the proposed infrastructure change as a plan in the PR,
    so that I can reason about its effect before it is applied.
30. As a future maintainer, I want resources consistently named (`rg-agentsteering-{env}`,
    `func-agentsteering-{env}`, etc.) and tagged (`environment`, `project`, `managedBy`),
    so that ownership and environment are obvious in the portal and in cost reports.

## Implementation Decisions

### Scope and topology
- **Multi-environment, real apply.** Two environments — `dev` and `prod` — both applied
  for real into a single Azure subscription, isolated by resource group
  (`rg-agentsteering-dev`, `rg-agentsteering-prod`).
- **Promotion model.** `main` auto-applies and deploys dev; prod apply + deploy is a gated
  continuation behind a GitHub Environment approval, not a manual one-off.

### Terraform structure
- **State backend.** A separate `infra/bootstrap/` Terraform config with committed *local*
  state creates the state resource group, storage account, and `tfstate` container. It is
  run once, locally, with the operator's `az login` — not the CI service principal. The
  main config then uses the `azurerm` remote backend.
- **Env modeling.** One root module (`infra/`) wrapping a reusable `infra/modules/`
  directory. Per-environment `infra/environments/dev.tfvars` + `prod.tfvars` and
  per-environment backend configs select state by blob key (`dev.tfstate`, `prod.tfstate`).
  CI passes the right `-var-file` and `-backend-config` per environment. No Terraform
  workspaces.
- **Modules (deep, single-responsibility, testable via `plan`):**
  - `storage` — Storage account for `AzureWebJobsStorage` plus the Flex Consumption
    deployment container.
  - `monitoring` — Log Analytics workspace + workspace-based Application Insights; outputs
    the connection string.
  - `functionapp` — Flex Consumption (FC1) Function App, `dotnet-isolated` runtime 8.0,
    system-assigned managed identity, app-settings composition. Always provisioned.
  - `keyvault` — RBAC-mode Key Vault, secret resources, and the role assignment granting
    the Function App's managed identity Key Vault Secrets User. Prod only.
  - `redis` — Azure Cache for Redis, Basic C0. Prod only.
  - `cosmos` — Cosmos DB account (serverless), SQL database, and container with partition
    key `/runId`. Prod only.
- **Tiered provisioning toggles.** Boolean variables (e.g. `enable_redis`, `enable_cosmos`)
  default off; `prod.tfvars` turns them on. Optional modules are `count`/`for_each`-gated
  on these flags.

### Hosting and runtime
- **Flex Consumption (FC1)**, `azurerm` provider `~> 4.0`, region `eastus` (FC1-capable).
  Runtime `dotnet-isolated`, version `8.0`. Durable Functions runs on Flex Consumption.

### Secrets
- **Key Vault references.** Prod's Redis and Cosmos connection strings are written to Key
  Vault; the Function App's `RedisConnection` / `CosmosConnection` app settings are
  `@Microsoft.KeyVault(SecretUri=...)` references resolved by the host via the app's
  managed identity. Application code is unchanged — it still reads the same setting names.
- **Acknowledged residual exposure.** Secret values transit Terraform state and may appear
  in an uploaded `tfplan` artifact; mitigated by a restricted remote backend, private and
  short-retention artifacts, and git-ignoring all state/plan files.

### CI/CD auth and pipeline
- **Auth.** Service principal credential JSON stored as the `AZURE_CREDENTIALS` GitHub
  secret. The same SP drives `azure/login` (for the deploy step) and the azurerm provider
  via `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` / `ARM_SUBSCRIPTION_ID`. The
  SP is granted **Owner** on the subscription (it must create resource groups and the
  Key Vault / Cosmos role assignments).
- **Workflows.** `ci.yml` is unchanged. A new single `cd.yml`:
  - **On PR:** `terraform fmt -check` (gate) · `terraform validate` (gate) · `plan(dev)`
    posted as a PR comment · Checkov scan (soft, comment) · optional `tflint`.
  - **On push to `main`:** `apply-dev` (apply saved plan) → `deploy-dev` →
    `[prod Environment approval]` → `plan-prod` (upload `tfplan`) → `apply-prod`
    (`terraform apply tfplan`) → `deploy-prod`.
  - `workflow_dispatch` enabled for manual runs.
- **Plan integrity.** Apply jobs run `terraform plan -out=tfplan`, upload the artifact, and
  apply that exact saved plan — the approver gates a frozen plan.
- **Deploy mechanism.** `dotnet publish -c Release` → zip → `Azure/functions-action@v1`.
  The Function App name and resource group are passed from the apply job to the deploy job
  via job outputs sourced from `terraform output`.
- **GitHub Environments.** `dev` (no protection) and `prod` (required reviewer = operator).
- **Conventions.** Names: `rg-agentsteering-{env}`, `func-agentsteering-{env}`,
  `stagentsteer{env}{rand}`, `kv-agentsteer-{env}-{rand}`, `cosmos-agentsteering-{env}`,
  `redis-agentsteering-{env}`. Tags: `environment`, `project=agentsteering`,
  `managedBy=terraform`. Pinned `.terraform.lock.hcl` committed.

## Testing Decisions

A good test here verifies *external, observable behavior and configuration intent*, not
the internal wiring of a particular resource block — and it must not require a live Azure
apply to run in CI on every PR.

- **Static IaC gates (run on every PR, blocking):** `terraform fmt -check` and
  `terraform validate` against the root config. These assert the configuration is
  syntactically valid and canonically formatted — the IaC analog of the existing
  `dotnet format --verify-no-changes` gate.
- **Security scan (run on PR, non-blocking initially):** Checkov over the Terraform,
  asserting the external security posture (e.g. storage not publicly exposed, HTTPS-only,
  minimum TLS) without coupling to specific resource internals.
- **Plan as review artifact:** `terraform plan` output on PRs is the primary behavioral
  check a human reviews — it shows the concrete intended change set before any apply.
- **Application tests unchanged:** the existing xUnit suite (`AgentSteeringService.Tests`,
  including the in-memory `DistributedLockTests` and the opt-in
  `CosmosRunHistoryStoreTests`) remains the behavioral coverage for application logic and
  continues to run in `ci.yml`. Prior art for store-level integration testing is the
  emulator-gated `CosmosRunHistoryStoreTests` (`COSMOS_TEST_CONNECTION`), which models how
  a real store is exercised only when its backing service is available.
- **Modules to "test":** all Terraform modules are validated via `validate` + `plan`; no
  module is given a bespoke unit-test harness (e.g. Terratest) in this PRD — see Out of
  Scope.

## Out of Scope

- Passwordless data-plane auth (Cosmos via AAD RBAC, Redis via Microsoft Entra). It would
  remove connection strings entirely but requires changing `CosmosClient` / Redis
  initialization in application code — beyond a CI/CD change.
- OIDC / workload-identity federation for GitHub → Azure. Deliberately deferred in favor of
  the simpler `AZURE_CREDENTIALS` service-principal secret.
- A third environment, blue/green or canary deployment, slot swaps, or rollback automation.
- Custom domains, TLS certificates, VNet integration, private endpoints, and WAF/front-door.
- Terratest or other programmatic infrastructure unit tests; a true Cosmos free-tier
  optimization across environments; cost-budget alerts.
- Changing the application's source, public API, or the existing `ci.yml` build/test/format
  steps.
- Automated creation of the Azure service principal, the GitHub secret, or the GitHub
  Environments — these are documented one-time manual setup steps.

## Further Notes

- **Bootstrap is intentionally manual and local.** It runs once with the operator's own
  credentials and emits the state storage account name, which is then placed into
  `dev.backend.hcl` / `prod.backend.hcl`. This keeps backend creation off the CI identity
  and avoids the remote-backend chicken-and-egg.
- **Strategy-pattern showcase.** The dev-in-memory / prod-real-stores split is a feature,
  not an accident: it demonstrates the repo's documented "blank connection string ⇒
  in-memory fallback" switch end-to-end across two live environments without touching call
  sites — consistent with `CLAUDE.md`'s "to switch implementations, set/clear the
  connection string" guidance.
- **Cost.** Redis Basic C0 (~$16/mo) is the only non-trivial standing cost and is confined
  to prod. Cosmos is serverless (near-zero idle); Flex Consumption and Storage are
  pay-per-use. Dev is effectively free.
- **Version coupling.** When upgrading, bump the `azurerm` provider and re-commit
  `.terraform.lock.hcl` together; keep Terraform `>= 1.9`. This mirrors the existing
  `.csproj` discipline of bumping the Worker SDK and DurableTask extension together.
- This PRD was synthesized from a structured design interview; every decision above was an
  explicit choice with stated alternatives, not a default.
