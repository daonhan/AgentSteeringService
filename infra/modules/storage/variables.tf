variable "name" {
  type        = string
  description = "Globally-unique storage account name."
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}
