resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.project}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# Workspace-based Application Insights, so the telemetry middleware wired in
# Program.cs reports in the cloud.
resource "azurerm_application_insights" "this" {
  name                = "appi-${var.project}-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id
  tags                = var.tags
}

# Fan-out target for the metric alerts. Created with no receivers on purpose —
# wiring a real email/webhook is an operator step, not a checked-in placeholder
# (the cross-project review flagged placeholder alert emails as an anti-pattern).
resource "azurerm_monitor_action_group" "this" {
  name                = "ag-${var.project}-${var.environment}"
  resource_group_name = var.resource_group_name
  short_name          = "ag-${var.environment}"
  tags                = var.tags
}
