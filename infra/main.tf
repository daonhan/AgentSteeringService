locals {
  # Single source of truth for the project slug used in every resource name and
  # the project tag. Threaded into the monitoring and functionapp modules as a
  # variable so those modules carry no hardcoded service name.
  project = "agentsteering"

  resource_group_name = "rg-${local.project}-${var.environment}"
  # Storage account (max 24 chars, no hyphens) keeps its own truncated slug.
  storage_account_name = "stagentsteer${var.environment}${random_string.suffix.result}"
  # The three remaining globally-unique names now carry random_string.suffix so a
  # fork/share cannot collide on their DNS labels (matching storage and Key Vault).
  function_app_name = "func-${local.project}-${var.environment}-${random_string.suffix.result}"
  redis_name        = "redis-${local.project}-${var.environment}-${random_string.suffix.result}"
  cosmos_name       = "cosmos-${local.project}-${var.environment}-${random_string.suffix.result}"
  # Key Vault (max 24 chars) keeps its own truncated slug and dedicated suffix.
  key_vault_name = "kv-agentsteer-${var.environment}-${try(random_string.kv_suffix[0].result, "")}"

  tags = {
    environment = var.environment
    project     = local.project
    managedBy   = "terraform"
  }
}

# Short suffix to make the globally-unique storage account name collision-safe.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# Separate suffix for the (also globally-unique) Key Vault name; only when enabled.
resource "random_string" "kv_suffix" {
  count   = var.enable_keyvault ? 1 : 0
  length  = 4
  upper   = false
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

module "storage" {
  source = "./modules/storage"

  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

module "monitoring" {
  source = "./modules/monitoring"

  project             = local.project
  environment         = var.environment
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# Prod-only stores, gated by the enable_* flags (off in dev → in-memory fallbacks).
module "redis" {
  source = "./modules/redis"
  count  = var.enable_redis ? 1 : 0

  name                = local.redis_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

module "cosmos" {
  source = "./modules/cosmos"
  count  = var.enable_cosmos ? 1 : 0

  name                = local.cosmos_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  database_name       = "agentsteering"
  container_name      = "runhistory"
  tags                = local.tags
}

# Holds the store connection strings; the Function App references them by URI.
module "keyvault" {
  source = "./modules/keyvault"
  count  = var.enable_keyvault ? 1 : 0

  name                = local.key_vault_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  redis_connection_string  = var.enable_redis ? module.redis[0].primary_connection_string : ""
  cosmos_connection_string = var.enable_cosmos ? module.cosmos[0].primary_sql_connection_string : ""

  tags = local.tags
}

module "functionapp" {
  source = "./modules/functionapp"

  name                = local.function_app_name
  project             = local.project
  environment         = var.environment
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  storage_account_name          = module.storage.account_name
  deployment_container_endpoint = module.storage.deployment_container_endpoint

  app_insights_connection_string = module.monitoring.app_insights_connection_string

  redis_connection_setting  = var.enable_keyvault ? module.keyvault[0].redis_secret_reference : ""
  cosmos_connection_setting = var.enable_keyvault ? module.keyvault[0].cosmos_secret_reference : ""

  tags = local.tags
}

# Grant the Function App's managed identity read access to the vault's secrets, so
# the host can resolve the @Microsoft.KeyVault(...) references. Lives at the root
# (not inside the keyvault module) to avoid a functionapp <-> keyvault module cycle.
resource "azurerm_role_assignment" "func_kv_secrets_user" {
  count = var.enable_keyvault ? 1 : 0

  scope                = module.keyvault[0].vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.functionapp.principal_id
}

# Grant the Function App's managed identity data-plane access to its backing storage
# account, so identity-based AzureWebJobsStorage and the Flex deployment container
# work without an account key (Phase 8). At the root (not the storage module) to
# avoid a storage <-> functionapp module cycle — same placement as the KV role above.
resource "azurerm_role_assignment" "func_storage_blob_owner" {
  scope                = module.storage.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = module.functionapp.principal_id
}

# --- Observability (Phase 4) ------------------------------------------------
# The diagnostics module and the metric alerts target the Function App, which
# already depends on `monitoring` (App Insights). Placing them inside the
# monitoring module would make monitoring depend on functionapp and create a
# module cycle, so they live at the root — same reasoning as the role
# assignment above. The action group itself has no such coupling and stays in
# the monitoring module; the alerts reference it by output.

# Export the Function App's host/function logs and platform metrics to the
# existing Log Analytics workspace. Metric categories are sourced from the
# metric list inside the module (correct by construction).
module "functionapp_diagnostics" {
  source = "./modules/diagnostics"

  name                       = "diag-${local.function_app_name}"
  target_resource_id         = module.functionapp.id
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
}

# Always-on: the Function App is returning server (5xx) errors.
resource "azurerm_monitor_metric_alert" "function_errors" {
  name                = "alert-func-5xx-${local.project}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [module.functionapp.id]
  description         = "Function App is returning server (5xx) errors."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = module.monitoring.action_group_id
  }

  tags = local.tags
}

# Store alerts exist only when the prod stores are provisioned.
resource "azurerm_monitor_metric_alert" "cosmos_throttled" {
  count = var.enable_cosmos ? 1 : 0

  name                = "alert-cosmos-429-${local.project}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [module.cosmos[0].id]
  description         = "Cosmos DB is throttling requests (HTTP 429)."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DocumentDB/databaseAccounts"
    metric_name      = "TotalRequests"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0

    dimension {
      name     = "StatusCode"
      operator = "Include"
      values   = ["429"]
    }
  }

  action {
    action_group_id = module.monitoring.action_group_id
  }

  tags = local.tags
}

resource "azurerm_monitor_metric_alert" "redis_evictions" {
  count = var.enable_redis ? 1 : 0

  name                = "alert-redis-evictions-${local.project}-${var.environment}"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [module.redis[0].id]
  description         = "Redis is evicting keys under memory pressure."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Cache/redis"
    metric_name      = "evictedkeys"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = module.monitoring.action_group_id
  }

  tags = local.tags
}
