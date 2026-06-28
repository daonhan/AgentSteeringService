variable "location" {
  type        = string
  description = "Azure region for the Terraform state backend."
  default     = "eastus"
}

variable "state_resource_group_name" {
  type        = string
  description = "Resource group that holds the Terraform state storage account."
  default     = "rg-agentsteering-tfstate"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the state backend resources."
  default = {
    project   = "agentsteering"
    managedBy = "terraform"
    purpose   = "tfstate"
  }
}
