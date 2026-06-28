output "vault_id" {
  description = "Key Vault resource ID; scope for the Function App's Secrets User grant."
  value       = azurerm_key_vault.this.id
}

# Versionless Key Vault references so the host picks up rotated secret values.
output "redis_secret_reference" {
  value = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.redis.versionless_id})"
}

output "cosmos_secret_reference" {
  value = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.cosmos.versionless_id})"
}
