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
  description = "Redis connection string to store as the RedisConnection secret."
  sensitive   = true
}

variable "cosmos_connection_string" {
  type        = string
  description = "Cosmos connection string to store as the CosmosConnection secret."
  sensitive   = true
}

variable "tags" {
  type = map(string)
}
