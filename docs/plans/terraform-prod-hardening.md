# Plan: Terraform Prod-Hardening

> Source PRD: [`docs/prd/terraform-prod-hardening.md`](../prd/terraform-prod-hardening.md)
> Follow-up to [`docs/plans/terraform-github-actions-cicd.md`](./terraform-github-actions-cicd.md).
> Target branch: `feature/terraform`. Nine thin tracer-bullet slices; each is one
> mergeable PR, verifiable on its own via `fmt`/`validate`/`plan`/Checkov before any apply.

## Architectural decisions

Durable decisions that apply across all phases:

- **Two-phase split on Azure-side coupling.** Phases 1–6 ("6a") touch only Terraform
  and workflow YAML and merge with no Azure round-trip. Phases 7–9 ("6b") require a
  federated credential and/or role assignments to exist in Azure first. 6a and 6b are
  independent; neither blocks the other.
- **Verification model (unchanged from prior plan).** Every phase is gated by
  `terraform fmt -check` + `terraform validate`, reviewed as the plan-as-PR-comment,
  and (from Phase 2 on) scanned by Checkov. Applies preserve plan integrity — the
  pipeline applies the exact saved `tfplan`. No phase requires a live apply to be
  reviewable.
- **Module shape (unchanged).** Each store/concern stays an interface module; optional
  modules remain `count`-gated on `enable_*`. Cross-module role assignments live at the
  **root** to avoid module cycles (matching the existing `func_kv_secrets_user`
  placement). New submodules follow the same `main`/`variables`/`outputs` layout.
- **`diagnostics` deep-module contract.** A new `infra/modules/diagnostics` takes
  `target_resource_id` + `log_analytics_workspace_id`, reads
  `azurerm_monitor_diagnostic_categories`, and sources **enabled logs from the log
  category list and enabled metrics from the metric category list** — correct by
  construction. It emits exactly one `azurerm_monitor_diagnostic_setting`. This is the
  one extracted deep module; everything else is an edit to an existing module.
- **Checkov gate scoping.** Checkov flips from soft to a **hard gate scoped to the
  hardening rules** (HTTPS-only, min TLS, storage public-access, identity/secret); all
  other findings stay comment-only. Once a rule is enforced in a phase, later phases
  keep it green.
- **State / backend model unchanged.** Partial `azurerm` backend, per-env
  `*.backend.hcl`, dev+prod sharing one (now deletion-protected) state account. The
  state store is intentionally *harder* to destroy than the app infra.
- **Naming and tags unchanged.** Existing `rg-/func-/st.../kv-/cosmos-/redis-` names and
  the `environment`/`project`/`managedBy` tag schema carry into all new resources.
- **No application source changes** in any phase.

---

## Phase 1: State-store durability

**User stories**: 1, 2, 3

### What to build

Make the Terraform state backend non-destroyable. In the `infra/bootstrap/` config:
add `prevent_destroy` to the state storage account and the `tfstate` container; add
30-day blob and container soft-delete retention; and add a `CanNotDelete` management
lock on the state resource group. Bootstrap is local-state and run once by the
operator — this phase is verified by `plan` against the bootstrap config, not the CD
pipeline.

### Acceptance criteria

- [x] `terraform plan` in `infra/bootstrap/` shows the retention policies and the
      management lock as the only adds, with **no replacement** of the existing state
      account or container. (Retention/lifecycle are in-place; lock is a pure add —
      correct by construction. Live plan needs the operator's Azure + local state.)
- [x] `prevent_destroy` is set on the state account and container; a `terraform
      destroy` (or a `-target` destroy of either) is refused at plan time.
- [x] Blob and container delete-retention are 30 days.
- [x] A `CanNotDelete` lock exists on the state resource group.
- [x] `fmt -check` and `validate` pass for the bootstrap config.

---

## Phase 2: Function App transport hardening + Checkov hard gate

**User stories**: 4, 5

### What to build

Enforce `https_only = true` and a minimum inbound TLS of 1.2 on the Flex Consumption
Function App. In the same PR, promote the existing soft Checkov job to a **blocking
gate** scoped to the transport/public-access/identity rule set, so this hardening (and
the storage hardening already in place) cannot regress.

### Acceptance criteria

- [ ] `plan` shows `https_only = true` and `minimum_tls_version = "1.2"` on the
      Function App, as an in-place update (no replacement).
- [ ] Checkov runs as a **required** check on PRs; the scoped HTTPS-only / min-TLS /
      storage-public-access rules fail the job when violated and pass now.
- [ ] Non-scoped Checkov findings remain reported as a comment without blocking.
- [ ] `fmt -check` and `validate` pass.

---

## Phase 3: Store-toggle guardrail

**User stories**: 6

### What to build

Add a precondition asserting that `enable_redis` or `enable_cosmos` implies
`enable_keyvault`, so a store can never be provisioned billed-but-unreachable (its
connection only wires through a Key Vault reference). Implemented as a `validation`
block (mirroring the existing `environment` validation) or a root `precondition`.

### Acceptance criteria

- [ ] With `enable_cosmos = true` (or `enable_redis = true`) and `enable_keyvault =
      false`, `terraform plan` fails fast with a clear error message naming the
      invariant.
- [ ] The existing `dev.tfvars` (all flags off) and `prod.tfvars` (all flags on) both
      still plan cleanly.
- [ ] `fmt -check` and `validate` pass.

---

## Phase 4: Observability — diagnostics module + alerts

**User stories**: 7, 8, 9, 10, 16

### What to build

Extract a reusable `infra/modules/diagnostics` deep module (per the architectural
contract above) and use it to export the Function App's logs and platform metrics to
the existing Log Analytics workspace. Add an `azurerm_monitor_action_group` and a
metric alert on Function App failures; when the prod stores exist, also alert on Cosmos
throttled requests / Redis evictions. The new resources appear in the plan-as-PR-comment.

### Acceptance criteria

- [ ] `plan` shows one `azurerm_monitor_diagnostic_setting` targeting the Function App
      and pointing at the existing LAW.
- [ ] The diagnostic setting's **metric** categories are sourced from the metric
      category list (not the log list) — platform metrics are actually enabled, not an
      empty set.
- [ ] An action group and at least the Function App failure alert are planned; store
      alerts are present only when `enable_cosmos`/`enable_redis` are on.
- [ ] The `diagnostics` module has its own `variables.tf`/`outputs.tf` and is consumed,
      not inlined.
- [ ] `fmt -check`, `validate`, and the Checkov gate pass.

---

## Phase 5: Module parameterization + global-name suffixes

**User stories**: 11, 12

### What to build

Replace the hardcoded `agentsteering` slug in the monitoring and functionapp modules
with a `project` variable threaded from root locals. Extend the existing
`random_string.suffix` to the Cosmos, Redis, and Function App names so all five
globally-unique names are collision-safe. Because renaming live resources forces
replacement, use `moved` blocks (or document an import/no-op path) so dev state is not
churned destructively.

### Acceptance criteria

- [ ] The `agentsteering` literal exists only in root locals; monitoring and
      functionapp take it as a variable.
- [ ] Cosmos, Redis, and Function App names include the random suffix.
- [ ] `plan` against existing dev state shows **no resource replacement** for already-
      deployed resources (handled via `moved`/import), or any unavoidable rename is
      called out explicitly in the PR.
- [ ] `fmt -check`, `validate`, and the Checkov gate pass.

---

## Phase 6: Pipeline safety

**User stories**: 13, 14, 15

### What to build

Harden `cd.yml`: add a `paths:` filter (`infra/**`, the workflow file) to the `push`
trigger so a code/docs-only commit no longer runs an infra apply or raises a prod
approval; add a non-cancelling `concurrency` group to the apply jobs; and add an
optional scheduled `terraform plan -detailed-exitcode` drift job per environment that
alerts (exit code 2) without applying.

### Acceptance criteria

- [ ] A commit touching only application/docs files does **not** trigger
      apply-dev/deploy/plan-prod.
- [ ] Two near-simultaneous infra pushes serialize on the concurrency group; an
      in-flight apply is never cancelled.
- [ ] A scheduled run reports drift via exit code 2 and performs no apply.
- [ ] Existing PR gates and the gated dev→prod DAG are unchanged.

---

## Phase 7: OIDC federation

**User stories**: 17, 18

### What to build

Replace the long-lived `AZURE_CREDENTIALS` client secret with GitHub→Azure OIDC
workload-identity federation. Add `permissions: id-token: write`; point `azure/login`
and the azurerm provider at `client-id`/`tenant-id`/`subscription-id` federation; remove
the secret and its `fromJson(...)` env wiring. (Requires the federated credential to be
created on the Azure app registration first — a documented one-time setup step.)

### Acceptance criteria

- [ ] The pipeline authenticates to Azure with no `AZURE_CREDENTIALS` secret present.
- [ ] `id-token: write` is granted only to the jobs that need it.
- [ ] A full dev apply + deploy succeeds end-to-end under OIDC.
- [ ] The prod approval gate and plan integrity still hold.

---

## Phase 8: Managed-identity storage auth

**User stories**: 19, 20

### What to build

Switch the Function App from key-based to identity-based access to its backing storage:
set the Flex app's storage auth to its system-assigned identity, use
`AzureWebJobsStorage__accountName`, and drop `storage_access_key` from app settings.
Grant the app identity Storage Blob Data Owner on the account (role assignment at the
root if it would otherwise cycle).

### Acceptance criteria

- [ ] No storage account key appears in the Function App's app settings or in plan
      output.
- [ ] The app identity holds Storage Blob Data Owner on the backing account.
- [ ] A dev apply + deploy runs and the Functions host starts (orchestrations/entities
      reach storage) without a key.
- [ ] The Checkov gate (no-storage-key rule) passes.

---

## Phase 9: Passwordless prod data-plane + doc sync

**User stories**: 21, 22, 23, 24

### What to build

Remove key/secret-based data-plane auth from the prod stores: Cosmos
`local_authentication_disabled = true` plus a SQL data-plane role assignment for the app
identity; Key Vault `purge_protection_enabled = true` and `network_acls`
(deny-default + Azure-services bypass); Redis Microsoft Entra auth for the app identity.
Update the residual-exposure note in the prior PRD/runbook to match the new posture
(no storage keys or store access keys shipped through state in prod).

### Acceptance criteria

- [ ] With `prod.tfvars` (stores on), `plan` shows Cosmos local-auth disabled + the app
      identity's SQL role, KV purge protection + network ACLs, and Redis Entra auth.
- [ ] No Cosmos/Redis access key is required by the app at runtime in prod.
- [ ] Key Vault rejects public access by default (Azure-services bypass only) and
      cannot be purged.
- [ ] The documented security posture (PRD residual-exposure note / runbook) reflects
      the removal of key-based auth.
- [ ] `fmt -check`, `validate`, and the Checkov gate pass.
