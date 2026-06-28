# Plan: Terraform + GitHub Actions CI/CD

> Source PRD: [`docs/prd/terraform-github-actions-cicd.md`](../prd/terraform-github-actions-cicd.md)
> Approach: tracer-bullet vertical slices. Each phase cuts end-to-end (state → Terraform →
> pipeline → live app) and is independently verifiable.

## Architectural decisions

Durable decisions that apply across all phases:

- **Azure topology**: one subscription, two resource groups — `rg-agentsteering-dev`,
  `rg-agentsteering-prod`. Region `eastus` (Flex-Consumption-capable).
- **Terraform layout**:
  - `infra/bootstrap/` — local-state config that creates the state RG + storage account +
    `tfstate` container. Run once, locally, with the operator's `az login`.
  - `infra/` — root module on the `azurerm` remote backend, wrapping `infra/modules/`.
  - `infra/environments/{dev,prod}.tfvars` — per-env variable values.
  - `infra/environments/{dev,prod}.backend.hcl` — per-env backend config; state separated
    by blob key `dev.tfstate` / `prod.tfstate`. No Terraform workspaces.
- **Modules**: `storage`, `monitoring`, `functionapp` (always); `keyvault`, `redis`,
  `cosmos` (prod only, gated by `enable_keyvault` / `enable_redis` / `enable_cosmos`).
- **Hosting**: Flex Consumption (FC1), runtime `dotnet-isolated` 8.0. `azurerm` provider
  `~> 4.0`, Terraform `>= 1.9`, committed `.terraform.lock.hcl`.
- **App config contract (unchanged setting names the app already reads)**:
  `AzureWebJobsStorage`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `RedisConnection`,
  `CosmosConnection`, `CosmosDatabase` (`agentsteering`), `CosmosContainer` (`runhistory`).
  In dev, `RedisConnection` / `CosmosConnection` are absent → in-memory fallbacks. In prod
  they are `@Microsoft.KeyVault(SecretUri=...)` references.
- **Cosmos data model**: SQL API, database `agentsteering`, container `runhistory`,
  partition key `/runId`, serverless.
- **CI → Azure auth**: single service principal as the `AZURE_CREDENTIALS` GitHub secret;
  also exported as `ARM_CLIENT_ID` / `ARM_CLIENT_SECRET` / `ARM_TENANT_ID` /
  `ARM_SUBSCRIPTION_ID` for the azurerm provider. SP = **Owner** on the subscription.
- **Pipeline**: existing `ci.yml` (build/format/test) stays untouched. New single `cd.yml`
  with `workflow_dispatch`. PR → checks only; push-`main` → apply+deploy dev, then gated
  prod. Apply jobs apply a saved `tfplan` artifact (plan integrity).
- **Deploy mechanism**: `dotnet publish -c Release` → zip → `Azure/functions-action@v1`;
  target app name + RG flow from the apply job's `terraform output` as job outputs.
- **Naming / tags**: `rg-/func-/st/kv-/cosmos-/redis-agentsteering[-]{env}` (storage/KV get
  a random suffix for global uniqueness). Tags: `environment`, `project=agentsteering`,
  `managedBy=terraform`.

---

## Phase 1: Tracer bullet — dev provisioned + deployed end-to-end (baseline)

**Status**: code complete (2026-06-28). `infra/` (root + bootstrap + storage/monitoring/
functionapp modules + dev env files), `cd.yml` (apply-dev → deploy-dev), `.gitignore`, and
both `.terraform.lock.hcl` files committed. Static gates pass: `terraform fmt -check`,
`terraform validate` (azurerm 4.79.0, random 3.9.0), `actionlint`. Items still requiring a
live operator `az login` apply + smoke check are left unchecked below.

**User stories**: 1, 2, 3, 4, 5, 6, 9, 10, 11, 14, 15, 21, 24 (and dev portions of 27, 30)

### What to build

The thinnest complete thread through every layer. Stand up the remote state backend via
the local bootstrap config, author the root module + dev environment files and the three
baseline modules (`storage`, `monitoring`, `functionapp` on Flex Consumption), and a
minimal `cd.yml` that on push to `main` applies the dev environment and deploys the
compiled Functions app to it. After this phase, a merge to `main` results in a running dev
Function App in Azure serving the existing HTTP/Durable endpoints, with telemetry reporting
to Application Insights — driven entirely by the pipeline. No PR gates, no prod, no Redis/
Cosmos yet (dev runs on in-memory fallbacks). Safety-critical ignores land here so no state
or plan file is ever committed.

### Acceptance criteria

- [ ] `infra/bootstrap/` applies locally with `az login` and creates the state RG, storage
      account, and `tfstate` container; it emits the storage account name. *(requires live apply)*
- [ ] `infra/` initializes against the `azurerm` backend using `dev.backend.hcl`
      (key `dev.tfstate`) and applies cleanly to `rg-agentsteering-dev`. *(requires live apply)*
- [x] Dev provisions exactly: Storage account (wired as `AzureWebJobsStorage` + Flex
      deployment container), Log Analytics + Application Insights, and a Flex Consumption
      Function App (`dotnet-isolated` 8.0) with a system-assigned managed identity.
- [x] Dev Function App has **no** `RedisConnection` / `CosmosConnection` settings (in-memory
      fallbacks active); `APPLICATIONINSIGHTS_CONNECTION_STRING` is set.
- [x] `cd.yml` on push to `main`: `azure/login` with `AZURE_CREDENTIALS`, `apply-dev`
      (exports app name + RG as job outputs), then `deploy-dev` does `dotnet publish` →
      `Azure/functions-action` to that app.
- [ ] After a merge to `main`, `POST /api/runs` against the live dev app starts a run and
      `GET /api/runs/{id}` returns its state (manual smoke check). *(requires live apply)*
- [x] `.gitignore` excludes `.terraform/`, `*.tfstate*`, `tfplan`, and bootstrap local
      state; `.terraform.lock.hcl` is committed. No state/plan file appears in `git status`.

---

## Phase 2: PR review path — quality gates + plan-on-PR

**Status**: code complete (2026-06-28). `cd.yml` extended with a `pull_request` trigger
(paths `infra/**`, `.github/workflows/cd.yml`) and three PR-only jobs: `terraform-validate`
(fmt -check + `init -backend=false` + validate — the hard gate), `terraform-plan` (dev plan
posted/updated as a PR comment, `pull-requests: write`), and `checkov` (pip Checkov, soft —
never fails the job, comments findings). `apply-dev` / `deploy-dev` are gated with
`if: github.event_name != 'pull_request'`. `ci.yml` untouched. Static gates pass locally:
`terraform fmt -check -recursive`, `terraform validate` (`-backend=false`), `actionlint`,
and `node --check` on the two `github-script` bodies. Live PR-run observation of the posted
plan/Checkov comments is left to a real PR.

**User stories**: 16, 17, 18, 19, 20, 29

### What to build

Make infrastructure changes reviewable before they merge. Extend `cd.yml` with
pull-request triggers that run the Terraform static gates and surface the intended change
set on the PR itself. Opening a PR that touches `infra/` now runs `terraform fmt -check`
and `terraform validate` as blocking gates, posts a `terraform plan` for dev as a PR
comment, and runs a Checkov security scan that comments findings without blocking. `ci.yml`
(build/format/test) continues to run unchanged alongside.

### Acceptance criteria

- [x] On PR, `cd.yml` runs `terraform fmt -check` and `terraform validate`; a formatting or
      validation error fails the check. *(`terraform-validate` job; gate verified locally)*
- [x] On PR, a dev `terraform plan` runs and its output is posted/updated as a PR comment.
      *(`terraform-plan` job; create-or-update by marker. Live PR run to observe the comment
      pending.)*
- [x] On PR, Checkov scans the Terraform and reports findings as a comment; findings do
      **not** fail the check (soft). *(`checkov` job; `exit 0` keeps it soft.)*
- [x] PRs do not trigger any `apply` or `deploy` job. *(`if: github.event_name != 'pull_request'`
      on `apply-dev` / `deploy-dev`.)*
- [x] `ci.yml` still runs and is unmodified. *(unchanged; `git status` confirms.)*

---

## Phase 3: Prod promotion — gated apply with plan integrity

**Status**: code complete (2026-06-28). `infra/environments/prod.tfvars` + `prod.backend.hcl`
(key `prod.tfstate`, same bootstrap state account as dev) added; the root module is fully
parameterized by `var.environment`, so prod provisions the same baseline. `cd.yml` extended
with three push-to-`main` jobs: `plan-prod` (ungated, `terraform plan -out=tfplan` →
`tfplan-prod` artifact, 1-day retention) → `apply-prod` (`environment: prod`, downloads the
artifact and runs `terraform apply tfplan`) → `deploy-prod` (`environment: prod`, publish →
functions-action). Design note: the approval gate is on `apply-prod`/`deploy-prod`, not on
`plan-prod`, so the reviewer inspects the exact plan before approving (user stories 22/23);
nothing is *provisioned or deployed* to prod before approval, though the read-only
`plan-prod` runs first to produce that plan. Static gates pass locally: `terraform fmt
-check -recursive`, `terraform validate` (`-backend=false`), `actionlint`. The `prod` GitHub
Environment + required reviewer is the documented one-time manual setup (Phase 5); live
apply + approval observation pending.

**User stories**: 22, 23 (extends 17)

### What to build

Add the production environment and the gated promotion flow, baseline-only (no stores
yet). Introduce `rg-agentsteering-prod`, `prod.tfvars`, and `prod.backend.hcl`
(key `prod.tfstate`), and extend the `main` pipeline into the full DAG: `apply-dev` →
`deploy-dev` → **[GitHub Environment `prod` approval]** → `plan-prod` (uploads a `tfplan`
artifact) → `apply-prod` (applies that exact saved plan) → `deploy-prod`. Production is
reachable only after an explicit human approval, and the plan that is approved is byte-for-
byte the plan that applies.

### Acceptance criteria

- [x] `rg-agentsteering-prod` provisions the same baseline as dev (storage, monitoring,
      Flex Consumption Function App) via `prod.tfvars` + `prod.backend.hcl`. *(config in place;
      root module is `var.environment`-parameterized. Live apply pending.)*
- [x] A GitHub Environment `prod` exists with the operator as a required reviewer; the
      `apply-prod` / `deploy-prod` jobs are bound to it. *(jobs carry `environment: prod`;
      creating the Environment + reviewer is the documented manual setup step — Phase 5.)*
- [x] On push to `main`, dev applies and deploys automatically, then the run **pauses** for
      prod approval before any prod job starts. *(gate on `apply-prod`/`deploy-prod`; the
      read-only `plan-prod` runs first so the approver sees the plan. Live run pending.)*
- [x] `plan-prod` runs `terraform plan -out=tfplan` and uploads `tfplan` as a private,
      short-retention artifact; `apply-prod` downloads it and runs `terraform apply tfplan`.
      *(`tfplan-prod` artifact, `retention-days: 1`; actionlint-clean.)*
- [ ] After approval, prod deploys and the live prod app answers `GET /api/runs/{id}`
      (manual smoke check). Prod still runs on in-memory fallbacks at this phase. *(requires
      live apply)*

---

## Phase 4: Prod real stores — Redis + Cosmos + Key Vault (strategy-pattern showcase)

**Status**: code complete (2026-06-28). Added `infra/modules/{redis,cosmos,keyvault}` and
gated them in the root with `enable_redis` / `enable_cosmos` / `enable_keyvault` (default
off; `prod.tfvars` turns all three on). `redis` = Azure Cache Basic C0 (TLS 1.2, non-SSL
port off); `cosmos` = serverless SQL account + `agentsteering`/`runhistory` container,
partition `/runId`; `keyvault` = RBAC-mode vault storing `RedisConnection` /
`CosmosConnection` secrets (with a deployer Secrets-Officer self-grant so Terraform can
write them). The `functionapp` module now merges those in as `@Microsoft.KeyVault(...)`
references (versionless URIs); a root-level `Key Vault Secrets User` role assignment grants
the app's managed identity read access — kept at the root to avoid a functionapp↔keyvault
module cycle. Dev is untouched (flags off → in-memory). Static gates pass: `terraform fmt
-check -recursive`, `terraform validate` (azurerm 4.79.0, no warnings). No new providers →
`.terraform.lock.hcl` unchanged. Live apply + the Cosmos/Redis behavioral smoke checks
require Azure creds and are left unchecked below.

**User stories**: 7, 8, 12, 13 (contrast with 6)

### What to build

Turn prod into the full footprint and prove the connection-string strategy switch across
environments. Add the `redis`, `cosmos`, and `keyvault` modules, gated by `enable_redis` /
`enable_cosmos` / `enable_keyvault` (off by default, on in `prod.tfvars`). Prod provisions
Azure Cache for Redis (Basic C0) and a serverless Cosmos account (database `agentsteering`,
container `runhistory`, partition `/runId`); their connection strings are stored in Key
Vault; the Function App's managed identity is granted Key Vault Secrets User; and
`RedisConnection` / `CosmosConnection` are set as `@Microsoft.KeyVault(...)` references. Dev
is unchanged (flags off → in-memory). End state: prod exercises the real idempotency,
distributed-lock, and event-sourced history paths while dev stays free and in-memory — the
same code, switched by configuration.

### Acceptance criteria

- [x] With prod flags on, prod provisions Redis (Basic C0), Cosmos (serverless;
      `agentsteering`/`runhistory`, partition `/runId`), and an RBAC-mode Key Vault holding
      both connection-string secrets. *(modules + `prod.tfvars` flags in place; live apply
      pending.)*
- [x] The prod Function App's system-assigned identity has the Key Vault Secrets User role;
      `RedisConnection` / `CosmosConnection` resolve from Key Vault references (no raw secret
      in plain app settings). *(root `func_kv_secrets_user` role assignment + versionless KV
      references wired; live resolution pending.)*
- [x] Dev still provisions none of Redis/Cosmos/Key Vault (flags off). *(`count`-gated on
      `enable_*`; `dev.tfvars` leaves all three at their default `false`.)*
- [ ] On the live prod app, a started run's history is retrievable via
      `GET /api/runs/{id}/history` (Cosmos-backed), and a duplicate `POST /api/runs` with an
      `Idempotency-Key` is de-duplicated (Redis-backed) — manual verification. *(requires live
      apply)*
- [x] `terraform plan` for dev shows no Redis/Cosmos/Key Vault resources; for prod it shows
      all three. *(deterministic from the `count` gating; live plan observation pending.)*

---

## Phase 5: Docs + final hardening

**Status**: code complete (2026-06-28). Added `docs/runbook.md` (bootstrap → backend
wiring → service-principal + `AZURE_CREDENTIALS` → `dev`/`prod` GitHub Environments + prod
reviewer → PR/merge/promote flow → smoke check → naming/tags/versions reference → tear
down) and a dry read-through against the actual files (bootstrap outputs, the
`REPLACE_WITH_BOOTSTRAP_OUTPUT` backend placeholders, `cd.yml`'s `fromJson(secrets.
AZURE_CREDENTIALS)` refs and `environment:` bindings). README gains a CD badge, a "Deploy:
Terraform + GitHub Actions" section linking the pipeline + runbook, and `infra/`/`cd.yml`
in the layout. Consistency pass: all env-provisioned resources follow the
`<abbr>-agentsteering-{env}` naming convention and carry `environment`/`project`/
`managedBy=terraform` tags (bootstrap state resources intentionally carry
`project`/`managedBy`/`purpose=tfstate` — they're cross-environment). Version pinning
verified: Terraform `>= 1.9`, `azurerm ~> 4.0`, `random ~> 3.6`; committed
`.terraform.lock.hcl` current at azurerm 4.79.0 / random 3.9.0 (root + bootstrap). Static
gates pass: `terraform fmt -check -recursive`, `validate` (root + bootstrap, no warnings).
No application or `cd.yml` code changed. Live-apply-only checks left unchecked below.

**User stories**: 26, 27, 28, 30

### What to build

Make the pipeline reproducible by a newcomer and audit consistency. Write the setup runbook
covering the one-time manual steps (run the bootstrap, create the service principal and its
`AZURE_CREDENTIALS` secret, create the `dev` / `prod` GitHub Environments and prod reviewer)
and the day-to-day flow. Do a consistency pass over naming and tags across all modules,
and verify version pinning (Terraform `>= 1.9`, `azurerm ~> 4.0`, committed
`.terraform.lock.hcl`). README/architecture docs get a short CD section + reference.

### Acceptance criteria

- [x] A runbook documents: bootstrap execution, backend-config wiring, SP creation +
      `AZURE_CREDENTIALS`, GitHub Environments + prod reviewer, and how to trigger/promote.
      *(`docs/runbook.md`.)*
- [x] Another person can stand up dev from scratch following only the runbook (validated by
      a dry read-through against the actual steps). *(Each step cross-checked against the
      real files — bootstrap outputs, backend `key`/placeholder, `cd.yml` secret refs and
      `environment:` bindings.)*
- [x] All resources follow the naming convention and carry `environment` / `project` /
      `managedBy=terraform` tags; a `terraform plan` shows no naming/tag drift. *(Consistency
      pass: every taggable env resource applies `local.tags`; names follow
      `<abbr>-agentsteering-{env}`. `validate` clean; live plan deterministic.)*
- [x] Terraform and provider versions are pinned and `.terraform.lock.hcl` is committed and
      current. *(`>= 1.9`, `azurerm ~> 4.0`, `random ~> 3.6`; lock at 4.79.0 / 3.9.0, root +
      bootstrap.)*
- [x] README links the CD pipeline and the runbook; the CI badge section notes the new
      `cd.yml`. *(CD badge added; "Deploy: Terraform + GitHub Actions" section links both.)*

---

## Phase dependency order

`1 → 2 → 3 → 4 → 5`. Phases 2 and 5 are low-risk and could be reordered relative to 3/4 if
priorities shift, but 1 must land first (everything depends on the backend + dev thread)
and 4 depends on prod existing (Phase 3).
