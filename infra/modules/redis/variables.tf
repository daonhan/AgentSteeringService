variable "name" {
  type        = string
  description = "Redis cache name (globally unique DNS label)."
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
