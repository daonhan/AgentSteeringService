locals {
  resource_group_name  = "rg-agentsteering-${var.environment}"
  storage_account_name = "stagentsteer${var.environment}${random_string.suffix.result}"
  function_app_name    = "func-agentsteering-${var.environment}"

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

  tags = local.tags
}
