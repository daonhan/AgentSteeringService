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

  tags = var.tags
}
