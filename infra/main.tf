locals {
  resource_group_name  = "rg-agentsteering-${var.environment}"
  storage_account_name = "stagentsteer${var.environment}${random_string.suffix.result}"
  function_app_name    = "func-agentsteering-${var.environment}"
  redis_name           = "redis-agentsteering-${var.environment}"
  cosmos_name          = "cosmos-agentsteering-${var.environment}"
  key_vault_name       = "kv-agentsteer-${var.environment}-${try(random_string.kv_suffix[0].result, "")}"

  tags = {
    environment = var.environment
    project     = "agentsteering"
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
  environment         = var.environment
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  storage_connection_string     = module.storage.primary_connection_string
  storage_access_key            = module.storage.primary_access_key
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
