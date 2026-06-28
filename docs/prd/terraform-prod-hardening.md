# PRD: Terraform Prod-Hardening for Agent Steering Service

> Status: Draft · Owner: daonhan · Target branch: `feature/terraform`
> Scope: Hardening the existing Terraform IaC + `cd.yml` pipeline toward
> production-credible defaults. Follow-up to
> [`terraform-github-actions-cicd.md`](./terraform-github-actions-cicd.md); pulls
> several items that PRD parked in *Out of Scope* (OIDC, passwordless data-plane
> auth) back in, plus fixes surfaced by a cross-project Terraform review against an
> external tutorial repo.

## Problem Statement

The Terraform + CD work (Phases 1–5) stood up a modular, multi-environment Azure
footprint with a gated dev→prod promotion. A cross-project review confirmed that
design is sound, but found a short list of gaps that are *not* documented scaffold
shortcuts — they are real prod-credibility and safety issues:

- The Terraform **state store has no deletion protection**. A stray `terraform
  destroy` on the bootstrap config, or a portal delete, would wipe the storage
  account holding *both* dev and prod state, with no soft-delete net.
- The pipeline authenticates to Azure with a **long-lived `AZURE_CREDENTIALS`
  client secret** instead of OIDC federation.
- The Function App **authenticates to its own storage with an account key** even
  though it already has a system-assigned managed identity — the key flows into
  app settings and Terraform state.
- The Flex Consumption app sets **no `https_only` and no minimum inbound TLS**.
- Observability stops at Log Analytics + Application Insights: **no diagnostic
  settings and no metric alerts**, so failures are not actively surfaced.
- A handful of correctness/cleanliness gaps: enabling a store without Key Vault
  provisions a **billed-but-unreachable** resource; a project slug is hardcoded
  into modules; only two of five globally-unique names carry a collision suffix;
  the `main` push trigger has **no path filter** (a code-only commit raises a prod
  approval); and there is no concurrency guard against overlapping applies.

As the operator I want these closed so the infrastructure is safe to run for real,
without re-architecting the working design.

## Solution

Two sequenced phases delivered as one PRD, split on whether a change needs
Azure-side identity setup first.

**Phase 6a — pure Terraform + pipeline (mergeable with no Azure round-trip).**
Add deletion protection to the state store; set `https_only` + minimum TLS on the
Flex app; add a variable precondition coupling the store toggles to Key Vault; add
real observability (a reusable diagnostics submodule + metric alerts wired to the
existing Log Analytics workspace); parameterize the hardcoded project slug and
extend the random suffix to the remaining global names; add a `paths:` filter and a
non-cancelling `concurrency` group to the pipeline; and promote the existing soft
Checkov scan to a blocking gate scoped to the new hardening rules.

**Phase 6b — identity-coupled (needs federated credentials / role assignments).**
Replace the `AZURE_CREDENTIALS` secret with GitHub→Azure OIDC federation; switch the
Function App to identity-based storage auth; and remove key/secret-based data-plane
auth from the prod stores (Cosmos local-auth disabled + SQL RBAC, Key Vault purge
protection + network ACLs, Redis Entra auth).

The whole change preserves the existing strategy-pattern showcase, the gated
promotion DAG, and the documented dev-in-memory / prod-real-stores split; no
application source changes.

## User Stories

### Phase 6a — state safety, transport, observability, hygiene

1. As the operator, I want the Terraform state storage account and `tfstate`
   container protected by `prevent_destroy`, so that a stray destroy of the
   bootstrap config cannot delete the state for both environments.
2. As the operator, I want blob and container soft-delete retention (30 days) on the
   state account, so that an accidental delete or overwrite of a state blob is
   recoverable.
3. As the operator, I want a `CanNotDelete` management lock on the state resource
   group, so that a portal-side delete of the state store is refused.
4. As the operator, I want the Flex Consumption Function App to enforce
   `https_only = true`, so that no plaintext HTTP request is ever served.
5. As the operator, I want a minimum inbound TLS version of 1.2 on the Function App,
   so that the public listener rejects legacy TLS — closing the same Checkov rules
   the storage account already satisfies.
6. As the operator, I want a precondition asserting that enabling Redis or Cosmos
   implies enabling Key Vault, so that I cannot provision a billed store the app
   will never reach (its connection only wires through a Key Vault reference).
7. As the operator, I want the Function App's logs exported to the existing Log
   Analytics workspace via a diagnostic setting, so that host and function logs are
   queryable and retained alongside the App Insights telemetry.
8. As the operator, I want the diagnostic setting built from the resource's actual
   *metric* category list (not its log category list), so that platform metrics are
   genuinely enabled rather than silently dropped.
9. As the operator, I want a reusable `diagnostics` submodule taking a target
   resource id and the workspace id, so that the metric/log category sourcing is
   correct by construction and reusable for any future resource.
10. As the operator, I want a metric alert on Function App failures (and, when the
    prod stores exist, Cosmos throttled requests / Redis evictions) wired to an
    action group, so that I am notified when the system degrades instead of
    discovering it later.
11. As the operator, I want the project slug passed as a variable into the
    monitoring and functionapp modules, so that the name lives only in root locals
    and the modules are reusable for another service.
12. As the operator, I want the Cosmos, Redis, and Function App names to carry the
    same random suffix the storage account and Key Vault already use, so that the
    config does not collide on globally-unique DNS labels if it is forked or shared.
13. As the operator, I want the `main` push trigger filtered to `infra/**` and the
    CD workflow file, so that a code- or docs-only commit does not run an infra apply
    and raise a prod approval.
14. As the operator, I want a non-cancelling `concurrency` group on the apply jobs,
    so that two quick pushes cannot run overlapping applies against shared state, and
    so that an in-flight apply is never cancelled mid-write.
15. As the operator, I want an optional scheduled `terraform plan -detailed-exitcode`
    per environment that alerts on drift (exit code 2) without applying, so that
    out-of-band portal changes are detected.
16. As a reviewer, I want the hardening changes to appear in the existing
    plan-as-PR-comment, so that I can see the exact new resources and settings before
    they apply.

### Phase 6b — identity-based auth

17. As the operator, I want GitHub Actions to authenticate to Azure via OIDC
    workload-identity federation (`id-token: write` + federated credential), so that
    no long-lived client secret is stored in GitHub.
18. As the operator, I want the `AZURE_CREDENTIALS` secret and its `fromJson`
    plumbing removed once OIDC is in place, so that there is a single, secretless
    auth path for both the provider and `azure/login`.
19. As the operator, I want the Function App to authenticate to its backing storage
    with its system-assigned managed identity (`AzureWebJobsStorage__accountName` +
    `StorageAccountConnectionString` replaced by identity), so that no storage
    account key is written into app settings or Terraform state.
20. As the operator, I want the Function App's identity granted Storage Blob Data
    Owner on the backing account, so that identity-based `AzureWebJobsStorage` and
    the Flex deployment container work without a key.
21. As the operator, I want Cosmos `local_authentication_disabled = true` plus a SQL
    data-plane role assignment for the app identity, so that the run-history store is
    reachable by RBAC rather than an account key.
22. As the operator, I want Key Vault `purge_protection_enabled = true` and
    `network_acls` defaulting to deny with an Azure-services bypass for prod, so that
    secrets cannot be hard-deleted and the vault is not openly reachable.
23. As the operator, I want Redis to accept Microsoft Entra (AAD) auth for the app
    identity in prod, so that the cache no longer depends on an access key.
24. As a future maintainer, I want the residual-exposure note in the prior PRD
    updated to reflect that prod no longer ships storage keys or store access keys
    through state, so that the documented security posture matches reality.

## Implementation Decisions

### Phasing and gating
- **One PRD, two phases**, split on Azure-side coupling. Phase 6a touches only
  Terraform and workflow YAML and can merge without any Azure identity setup. Phase
  6b requires a federated credential and role assignments to exist first.
- Phase 6b is **not** a prerequisite for 6a; each phase is independently shippable.

### Modules built / modified
- **`bootstrap` (modified).** Add `lifecycle { prevent_destroy = true }` to the state
  account and container; add `delete_retention_policy` + `container_delete_retention_policy`
  (30 days) under `blob_properties`; add an `azurerm_management_lock` (`CanNotDelete`)
  on the state resource group.
- **`diagnostics` (new, deep, reusable).** Inputs: `target_resource_id`,
  `log_analytics_workspace_id`, and optional category overrides. It reads
  `azurerm_monitor_diagnostic_categories` and sources **enabled metrics from the
  metric category list and enabled logs from the log category list** — the sourcing
  is correct by construction, eliminating the class of bug where metrics are
  intersected against log categories and silently never enabled. Emits one
  `azurerm_monitor_diagnostic_setting`. Single responsibility, validated by `plan`.
- **`monitoring` (modified).** Consume the new `diagnostics` submodule for the
  Function App; add an `azurerm_monitor_action_group` and metric alert(s)
  (function errors always; Cosmos 429s / Redis evictions when those stores exist).
  Take a `project` variable instead of the hardcoded slug.
- **`functionapp` (modified).** Add `https_only = true` and
  `site_config { minimum_tls_version = "1.2" }`. Take a `project` variable. (6b)
  Switch `storage_authentication_type` to `SystemAssignedIdentity` and use
  identity-based `AzureWebJobsStorage__accountName`, dropping `storage_access_key`.
- **`storage` (modified, 6b).** Add a role assignment granting the Function App
  identity Storage Blob Data Owner (kept at the root if it would create a module
  cycle, matching the existing Key Vault role-assignment placement).
- **`cosmos` (modified, 6b).** `local_authentication_disabled = true`; add a
  `azurerm_cosmosdb_sql_role_assignment` for the app identity.
- **`keyvault` (modified, 6b).** `purge_protection_enabled = true`; add
  `network_acls { default_action = "Deny", bypass = "AzureServices" }`.
- **`redis` (modified, 6b).** Enable Entra (AAD) auth and an access-policy assignment
  for the app identity.
- **Root `main.tf` / `variables.tf` (modified).** Add the `enable_redis`/`enable_cosmos`
  ⇒ `enable_keyvault` precondition (a `validation` block mirroring the existing
  `environment` validation, or a `check`/`precondition`); thread the `project`
  variable into modules; extend `random_string.suffix` into the Cosmos/Redis/Function
  App names; wire the new data-plane role assignments.

### Pipeline (`cd.yml`)
- Add `paths: [infra/**, .github/workflows/cd.yml]` to the `push` trigger.
- Add `concurrency: { group: terraform-${{ github.ref }}, cancel-in-progress: false }`
  to the apply jobs — never cancel an in-flight apply.
- **Phase 6b auth:** add `permissions: id-token: write`; switch `azure/login` and the
  azurerm provider to `client-id` / `tenant-id` / `subscription-id` federation; delete
  the `AZURE_CREDENTIALS` secret and the `fromJson(...)` env wiring.
- Optional Phase 6a: a scheduled `plan -detailed-exitcode` drift job per environment.

### Conventions preserved
- Existing names, the `environment`/`project`/`managedBy` tag schema, the partial
  backend + per-env `*.backend.hcl`, the gated dev→prod DAG, and plan-integrity
  (apply the saved `tfplan`) are unchanged. New resources adopt the same names/tags.

## Testing Decisions

A good test here asserts *external, observable configuration intent* and must not
require a live Azure apply on every PR — consistent with the prior PRD.

- **Checkov promoted to a hard gate (scoped).** The existing soft Checkov job becomes
  blocking for the specific hardening rules this PRD introduces — HTTPS-only and
  minimum TLS on the Function App (CKV_AZURE_70 / CKV_AZURE_145-class), storage
  public-access, and identity/secret rules — so a regression that drops `https_only`,
  weakens TLS, or reintroduces a storage key fails the PR. Other Checkov findings stay
  informational (comment-only) to avoid one opinionated rule wedging the pipeline.
- **`fmt -check` + `validate` unchanged** as blocking gates on every PR.
- **Plan as the behavioral review artifact.** The diagnostics submodule, the metric
  alerts, the precondition, and the state-lock changes are all reviewed in the
  existing plan-as-PR-comment; the precondition additionally fails `plan` fast if the
  enable-flag invariant is violated, which is itself a test of the guardrail.
- **Diagnostics correctness by construction, not by harness.** The bug class this PRD
  guards against (metrics intersected against log categories → silently empty) is
  eliminated by the submodule sourcing metric categories from the metric list; no
  bespoke Terratest/`.tftest.hcl` harness is added (consistent with the repo's
  no-IaC-unit-test posture).
- **Application tests unchanged.** The xUnit suite (`AgentSteeringService.Tests`,
  including the in-memory `DistributedLockTests` and emulator-gated
  `CosmosRunHistoryStoreTests`) remains the behavioral coverage and continues to run
  in `ci.yml`.

## Out of Scope

- **The external tutorial repo's own defects.** The review surfaced real bugs in the
  separate `from-zero-to-hero` project (undefined dynamic-block iterator + wrong
  metric-category source, shared single state key, broken plan integrity, plaintext
  secrets, a `FUNCTION_WORKER_RUNTIME` typo, placeholder alert email). Those belong to
  that repo, not this codebase; they motivated several stories here but are not fixed
  by this PRD.
- **Private endpoints / VNet integration / Front Door / WAF.** Phase 6b removes
  key-based data-plane auth and adds network ACLs, but keeps public network endpoints
  (with deny-by-default + Azure-services bypass). Full network isolation stays out of
  scope, as in the prior PRD.
- **Separate prod state account.** Dev and prod still share one state storage account
  (now deletion-protected). Giving prod its own state account for independent RBAC is
  noted as a future option, not delivered here.
- **Blue/green, canary, slot swaps, rollback automation, cost-budget alerts.**
- **Terratest or other programmatic infrastructure unit tests.**
- **Application source, public API, or `ci.yml` build/test/format steps.**

## Further Notes

- **Ordering within 6b.** Create the federated credential and grant the data-plane
  roles before flipping the corresponding auth flag, so the pipeline does not lock
  itself out mid-migration. OIDC (stories 17–18) is the safest 6b item to land first;
  the passwordless store changes (21–23) only matter when `enable_*` are on (prod).
- **Why the precondition matters (story 6).** Today `enable_redis`/`enable_cosmos`
  only wire a connection into the app when `enable_keyvault` is also true; enabling a
  store alone provisions a billed resource the app cannot use. The precondition turns
  that silent misconfiguration into a fast `plan`-time error.
- **State lock vs. teardown.** `prevent_destroy` and the management lock intentionally
  make the *state store* hard to tear down; this is the opposite of the deliberately
  tear-down-friendly Key Vault (`purge_protection = false`) in the prior PRD. The
  asymmetry is correct — losing application infra is recoverable from code, losing
  state is not.
- **Borrowed instinct, not code.** The observability stories adapt a pattern observed
  in the reviewed tutorial (diagnostic settings + DLQ-style metric alerts) but deliver
  it via a correct reusable submodule and managed-identity RBAC, not the tutorial's
  copy-pasted blocks and SAS connection strings.
- **Cost.** All Phase 6a additions are effectively free (alerts, diagnostic settings,
  soft-delete retention, a management lock). Phase 6b changes auth mode, not SKU, so
  no standing-cost change beyond the existing Redis Basic C0 in prod.
