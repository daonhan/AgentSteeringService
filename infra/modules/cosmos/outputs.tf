output "id" {
  value = azurerm_cosmosdb_account.this.id
}

# Endpoint only — no AccountKey. With local auth disabled the app authenticates by
# its managed identity (AAD RBAC), so this carries no secret into state.
output "endpoint" {
  description = "Cosmos account endpoint (no key) for the CosmosConnection secret."
  value       = azurerm_cosmosdb_account.this.endpoint
}
