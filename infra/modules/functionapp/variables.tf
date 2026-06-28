variable "name" {
  type        = string
  description = "Function App name."
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

variable "storage_connection_string" {
  type        = string
  description = "AzureWebJobsStorage connection string (Durable + runtime backing store)."
  sensitive   = true
}

variable "storage_access_key" {
  type        = string
  description = "Access key for the Flex Consumption deployment container."
  sensitive   = true
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

variable "tags" {
  type = map(string)
}
