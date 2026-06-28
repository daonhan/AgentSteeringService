output "id" {
  value = azurerm_storage_account.this.id
}

output "account_name" {
  value = azurerm_storage_account.this.name
}

output "deployment_container_endpoint" {
  description = "Blob endpoint of the Flex Consumption deployment container."
  value       = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deployments.name}"
}
