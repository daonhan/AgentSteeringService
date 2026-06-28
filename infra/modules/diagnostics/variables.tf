variable "name" {
  type        = string
  description = "Name of the diagnostic setting."
}

variable "target_resource_id" {
  type        = string
  description = "Resource whose logs and platform metrics are exported."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Log Analytics workspace the diagnostics are sent to."
}
