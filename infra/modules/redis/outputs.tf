output "primary_connection_string" {
  description = "StackExchange.Redis-compatible connection string for RedisConnection."
  value       = azurerm_redis_cache.this.primary_connection_string
  sensitive   = true
}
