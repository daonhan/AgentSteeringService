variable "environment" {
  type        = string
  description = "Deployment environment; selects names, tags and the state blob key."

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either \"dev\" or \"prod\"."
  }
}

variable "location" {
  type        = string
  description = "Azure region. Must be Flex-Consumption-capable."
  default     = "eastus"
}

# Tiered provisioning toggles. Default off (dev → in-memory fallbacks); prod.tfvars
# turns all three on together to provision the real stores + Key Vault references.
variable "enable_redis" {
  type        = bool
  description = "Provision Azure Cache for Redis and wire RedisConnection."
  default     = false
}

variable "enable_cosmos" {
  type        = bool
  description = "Provision Cosmos DB and wire CosmosConnection."
  default     = false
}

variable "enable_keyvault" {
  type        = bool
  description = "Provision Key Vault holding the store secrets, referenced from app settings."
  default     = false
}
