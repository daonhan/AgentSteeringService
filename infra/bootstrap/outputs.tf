output "state_resource_group_name" {
  description = "Resource group holding the Terraform state storage account."
  value       = azurerm_resource_group.state.name
}

output "state_storage_account_name" {
  description = "Storage account name to copy into environments/*.backend.hcl."
  value       = azurerm_storage_account.state.name
}

output "state_container_name" {
  description = "Blob container holding the per-environment state files."
  value       = azurerm_storage_container.tfstate.name
}
