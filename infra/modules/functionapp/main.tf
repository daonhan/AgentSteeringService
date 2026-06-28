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

  # Transport hardening: serve only HTTPS and reject pre-1.2 TLS on the public listener.
  https_only = true

  site_config {
    minimum_tls_version = "1.2"
  }

  # Baseline settings are always present. RedisConnection / CosmosConnection are
  # added only when supplied (prod, as Key Vault references); when empty the app
  # runs on its in-memory fallbacks (the strategy-pattern switch).
  app_settings = merge(
    {
      AzureWebJobsStorage                   = var.storage_connection_string
      APPLICATIONINSIGHTS_CONNECTION_STRING = var.app_insights_connection_string
    },
    var.redis_connection_setting != "" ? { RedisConnection = var.redis_connection_setting } : {},
    var.cosmos_connection_setting != "" ? { CosmosConnection = var.cosmos_connection_setting } : {},
  )

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}
