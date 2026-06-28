output "primary_sql_connection_string" {
  description = "AccountEndpoint=...;AccountKey=...; connection string for CosmosConnection."
  value       = azurerm_cosmosdb_account.this.primary_sql_connection_string
  sensitive   = true
}
