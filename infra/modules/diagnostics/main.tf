# Reusable diagnostic-settings module. The metric categories are sourced from the
# resource's metric-category list and the logs from its log-category list, so
# platform metrics are genuinely enabled. The classic bug — metrics intersected
# against the log categories and therefore silently never enabled — is impossible
# here by construction. Emits exactly one diagnostic setting.
data "azurerm_monitor_diagnostic_categories" "this" {
  resource_id = var.target_resource_id
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = var.name
  target_resource_id         = var.target_resource_id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  dynamic "enabled_log" {
    for_each = data.azurerm_monitor_diagnostic_categories.this.log_category_types
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = data.azurerm_monitor_diagnostic_categories.this.metrics
    content {
      category = enabled_metric.value
    }
  }
}
