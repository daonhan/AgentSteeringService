# Azure Cache for Redis, Basic C0 — the smallest real tier. Backs the
# idempotency store and the per-run distributed lock in prod (in dev these
# fall back to in-memory because RedisConnection is left unset).
resource "azurerm_redis_cache" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  capacity = 0
  family   = "C"
  sku_name = "Basic"

  non_ssl_port_enabled = false
  minimum_tls_version  = "1.2"

  # Passwordless data-plane auth (Phase 9): accept Microsoft Entra (AAD) tokens so
  # the app identity can authenticate without an access key. The app's data-access
  # policy is assigned at the root (azurerm_redis_cache_access_policy_assignment),
  # and only the keyless host:port endpoint is shipped to the app.
  redis_configuration {
    active_directory_authentication_enabled = true
  }

  tags = var.tags
}
