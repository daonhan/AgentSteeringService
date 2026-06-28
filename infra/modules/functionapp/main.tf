resource "azurerm_service_plan" "this" {
  name                = "asp-agentsteering-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = var.deployment_container_endpoint
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = var.storage_access_key

  runtime_name    = "dotnet-isolated"
  runtime_version = "8.0"

  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  site_config {}

  # Only the baseline settings. RedisConnection / CosmosConnection are deliberately
  # absent so the app runs on its in-memory fallbacks (the strategy-pattern switch).
  app_settings = {
    AzureWebJobsStorage                   = var.storage_connection_string
    APPLICATIONINSIGHTS_CONNECTION_STRING = var.app_insights_connection_string
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}
