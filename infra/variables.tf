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
