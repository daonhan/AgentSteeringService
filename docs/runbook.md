# CD Runbook — standing up & operating the pipeline

How to provision the Azure infrastructure and operate the GitHub Actions delivery
pipeline for this service, from a cold start. The [PRD](prd/terraform-github-actions-cicd.md)
and [plan](plans/terraform-github-actions-cicd.md) explain *why*; this is the *how*.

Two parts:

- **[One-time setup](#one-time-setup)** — the manual steps a person does once (run the
  bootstrap, wire the backend, create the service principal + secret, create the GitHub
  Environments). These are deliberately not automated (see the PRD's *Out of Scope*).
- **[Day-to-day flow](#day-to-day-flow)** — how changes reach dev and get promoted to prod.

```
infra/bootstrap (local state, your az login)  ──once──►  state storage account
        │ emits state_storage_account_name
        ▼  paste into environments/{dev,prod}.backend.hcl
cd.yml (CI service principal)  ──push to main──►  apply-dev → deploy-dev
                                                  → plan-prod → [prod approval] → apply-prod → deploy-prod
```

---

## Prerequisites

- An Azure subscription and the **Azure CLI** (`az`), logged in as a user with **Owner**
  (you create a subscription-scoped role assignment for the service principal).
- **Terraform `>= 1.9`** locally (CI pins `1.9.8`).
- Admin on the GitHub repository (to add the secret and create Environments).

---

## One-time setup

### 1. Run the bootstrap (creates the Terraform state backend)

The remote backend can't store its own state, so a small local-state config creates it
once. Run it with **your own** `az login`, not the CI service principal.

```bash
az login
az account set --subscription "<your-subscription-id>"

cd infra/bootstrap
terraform init
terraform apply        # creates rg-agentsteering-tfstate + a storage account + the tfstate container

terraform output state_storage_account_name   # note this value for step 2
```

This provisions `rg-agentsteering-tfstate`, a globally-unique storage account
(`sttfstate<random>`), and a private `tfstate` container with blob versioning on. Its
local state lives in `infra/bootstrap/terraform.tfstate` — git-ignored, keep it (it's how
you'd later destroy the backend).

### 2. Wire the backend config

Paste the storage account name from step 1 into **both** backend configs, replacing the
`REPLACE_WITH_BOOTSTRAP_OUTPUT` placeholder:

- `infra/environments/dev.backend.hcl`  → `key = "dev.tfstate"`
- `infra/environments/prod.backend.hcl` → `key = "prod.tfstate"`

Both point at the same storage account and container; **the blob `key` is the only thing
separating dev and prod state**, so the two environments can never select each other's
state by accident. Commit the filled-in values.

### 3. Create the CI service principal + `AZURE_CREDENTIALS` secret

The pipeline authenticates with one service principal, granted **Owner** on the
subscription (it must create resource groups and the Key Vault / Cosmos role assignments).

```bash
az ad sp create-for-rbac \
  --name "sp-agentsteering-cicd" \
  --role Owner \
  --scopes /subscriptions/<your-subscription-id> \
  --sdk-auth
```

Copy the **entire JSON** output (it has `clientId` / `clientSecret` / `tenantId` /
`subscriptionId`) into a GitHub repository secret named **`AZURE_CREDENTIALS`**
(*Settings → Secrets and variables → Actions → New repository secret*). The same secret
drives both `azure/login` (deploy) and the azurerm provider — `cd.yml` reads
`fromJson(secrets.AZURE_CREDENTIALS).clientId` into `ARM_CLIENT_ID` and so on.

### 4. Create the GitHub Environments

Under *Settings → Environments*:

| Environment | Protection |
|---|---|
| `dev`  | none |
| `prod` | **Required reviewers** = you (the operator) |

The `cd.yml` jobs are bound to these (`environment: dev` / `environment: prod`). The
required reviewer on `prod` is what pauses the run for approval before any prod job.

---

## Day-to-day flow

### Pull requests — review before merge

Opening a PR that touches `infra/**` (or `cd.yml`) runs the PR-only jobs in `cd.yml`:

- **`terraform fmt -check` + `terraform validate`** — hard gates; a formatting or
  validation error fails the check.
- **`terraform plan` (dev)** — posted/updated as a PR comment so the change set is
  reviewable before merge.
- **Checkov** — security scan; comments findings but never blocks (soft gate).

`ci.yml` (build / format / test) keeps running unchanged alongside. No `apply` or `deploy`
job runs on a PR.

### Merge to `main` — dev auto, prod gated

A push to `main` (or a manual **`workflow_dispatch`** run) runs the delivery DAG:

```
apply-dev → deploy-dev → plan-prod → [prod approval] → apply-prod → deploy-prod
```

1. **`apply-dev`** applies the dev environment and exports the Function App name + RG as
   job outputs.
2. **`deploy-dev`** does `dotnet publish -c Release` → `Azure/functions-action` to that app.
3. **`plan-prod`** runs `terraform plan -out=tfplan` and uploads the `tfplan` artifact
   (private, 1-day retention). It runs *before* the gate so the approver can inspect the
   exact plan.
4. **prod approval** — the run pauses on the `prod` Environment; an `apply-prod` /
   `deploy-prod` reviewer must approve.
5. **`apply-prod`** downloads that artifact and runs `terraform apply tfplan` — the
   byte-for-byte plan you approved is the plan that applies (plan integrity).
6. **`deploy-prod`** publishes and deploys to the prod app.

### Smoke check a live environment

After a deploy, against the app's default hostname (`terraform output
function_app_default_hostname`):

```bash
# start a run
curl -sX POST "https://<host>/api/runs?code=<function-key>" \
  -H 'Content-Type: application/json' \
  -d '{"instruction":"smoke test","maxSteps":3}'

# read its state back
curl -s "https://<host>/api/runs/<runId>?code=<function-key>"
```

In **dev** the run uses in-memory fallbacks (no Redis/Cosmos/Key Vault provisioned). In
**prod** the same code resolves `RedisConnection` / `CosmosConnection` from Key Vault
references, so `GET /api/runs/{id}/history` is Cosmos-backed and a duplicate `POST` with an
`Idempotency-Key` header is Redis-de-duplicated.

---

## Reference

### What each environment provisions

| Resource | Dev | Prod |
|---|---|---|
| Resource group, Storage, Log Analytics + App Insights, Flex Consumption Function App | ✅ | ✅ |
| Redis (Basic C0), Cosmos (serverless), Key Vault | — (in-memory fallbacks) | ✅ |

Prod's extra stores are gated by `enable_redis` / `enable_cosmos` / `enable_keyvault`,
which default `false` and are set `true` only in `prod.tfvars`.

### Naming & tags

| Resource | Name | Tags |
|---|---|---|
| Resource group | `rg-agentsteering-{env}` | `environment`, `project=agentsteering`, `managedBy=terraform` |
| Function App | `func-agentsteering-{env}` | ″ |
| Service plan | `asp-agentsteering-{env}` | ″ |
| Storage | `stagentsteer{env}{rand}` | ″ |
| Log Analytics / App Insights | `log-` / `appi-agentsteering-{env}` | ″ |
| Key Vault | `kv-agentsteer-{env}-{rand}` | ″ |
| Cosmos | `cosmos-agentsteering-{env}` | ″ |
| Redis | `redis-agentsteering-{env}` | ″ |

The bootstrap state resources carry `project` / `managedBy` / `purpose=tfstate` but no
`environment` tag — the state backend is shared across both environments by design.

### Version pinning

Terraform `>= 1.9`, `azurerm ~> 4.0`, `random ~> 3.6`; the resolved versions are locked in
the committed `.terraform.lock.hcl` (root and bootstrap). When upgrading the provider,
re-run `terraform init -upgrade` and commit the updated lock file.

### Tear down

```bash
cd infra && terraform destroy -var-file=environments/dev.tfvars   # or prod.tfvars
cd infra/bootstrap && terraform destroy                            # last — removes the state backend
```
