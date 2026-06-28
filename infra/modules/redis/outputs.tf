output "id" {
  value = azurerm_redis_cache.this.id
}

# Keyless endpoint — no access key. With Entra auth the app connects with an AAD
# token, so this carries no secret into state.
output "hostname" {
  description = "Redis hostname for the keyless RedisConnection endpoint."
  value       = azurerm_redis_cache.this.hostname
}

output "ssl_port" {
  description = "Redis TLS port for the keyless RedisConnection endpoint."
  value       = azurerm_redis_cache.this.ssl_port
}
