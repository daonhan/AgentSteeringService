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

variable "tags" {
  type = map(string)
}
