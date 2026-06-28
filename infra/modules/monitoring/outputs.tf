output "app_insights_connection_string" {
  value     = azurerm_application_insights.this.connection_string
  sensitive = true
}

output "log_analytics_workspace_id" {
  description = "Workspace ID; diagnostics target it."
  value       = azurerm_log_analytics_workspace.this.id
}

output "action_group_id" {
  description = "Action group the metric alerts notify."
  value       = azurerm_monitor_action_group.this.id
}
