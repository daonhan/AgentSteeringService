variable "name" {
  type        = string
  description = "Function App name."
}

variable "project" {
  type        = string
  description = "Project slug used in resource names; passed from root locals."
}

variable "environment" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "storage_account_name" {
  type        = string
  description = "Backing storage account name; identity-based AzureWebJobsStorage + deployment container auth use it (no key)."
}

variable "deployment_container_endpoint" {
  type        = string
  description = "Blob endpoint of the Flex Consumption deployment container."
}

variable "app_insights_connection_string" {
  type        = string
  description = "Application Insights connection string."
  sensitive   = true
}

variable "redis_connection_setting" {
  type        = string
  description = "RedisConnection app-setting value (a Key Vault reference in prod). Empty omits the setting → in-memory fallback."
  default     = ""
}

variable "cosmos_connection_setting" {
  type        = string
  description = "CosmosConnection app-setting value (a Key Vault reference in prod). Empty omits the setting → in-memory fallback."
  default     = ""
}

variable "tags" {
  type = map(string)
}
