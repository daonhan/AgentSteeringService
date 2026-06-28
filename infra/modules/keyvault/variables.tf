variable "name" {
  type        = string
  description = "Key Vault name (globally unique, <= 24 chars)."
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "redis_connection_string" {
  type        = string
  description = "Keyless Redis endpoint (host:ssl_port) stored as the RedisConnection secret; auth is via the app's Entra identity, so no access key is shipped."
}

variable "cosmos_connection_string" {
  type        = string
  description = "Keyless Cosmos endpoint stored as the CosmosConnection secret; auth is via the app's AAD identity, so no account key is shipped."
}

variable "tags" {
  type = map(string)
}
