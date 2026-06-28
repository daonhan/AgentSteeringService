output "resource_group_name" {
  description = "Resource group the environment was provisioned into."
  value       = azurerm_resource_group.this.name
}

output "function_app_name" {
  description = "Function App name; consumed by the deploy job."
  value       = module.functionapp.name
}

output "function_app_default_hostname" {
  description = "Default hostname of the Function App (for smoke checks)."
  value       = module.functionapp.default_hostname
}
