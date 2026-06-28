variable "name" {
  type        = string
  description = "Cosmos DB account name (globally unique DNS label)."
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "database_name" {
  type        = string
  description = "SQL database name (the app's CosmosDatabase, default agentsteering)."
}

variable "container_name" {
  type        = string
  description = "SQL container name (the app's CosmosContainer, default runhistory)."
}

variable "tags" {
  type = map(string)
}
