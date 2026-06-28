output "diagnostic_setting_id" {
  description = "ID of the emitted diagnostic setting."
  value       = azurerm_monitor_diagnostic_setting.this.id
}
