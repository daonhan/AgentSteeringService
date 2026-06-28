resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-agentsteering-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# Workspace-based Application Insights, so the telemetry middleware wired in
# Program.cs reports in the cloud.
resource "azurerm_application_insights" "this" {
  name                = "appi-agentsteering-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id
  tags                = var.tags
}
