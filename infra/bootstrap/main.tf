terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state on purpose: this config creates the remote backend that every
  # other config uses, so it cannot itself live in that backend (chicken-and-egg).
  # Run once, locally, with the operator's own `az login`.
  backend "local" {}
}

provider "azurerm" {
  features {}
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_resource_group" "state" {
  name     = var.state_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "state" {
  name                     = "sttfstate${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.state.name
  location                 = azurerm_resource_group.state.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true

    # Soft-delete nets: an accidental delete/overwrite of a state blob (or the
    # whole container) is recoverable for 30 days.
    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = var.tags

  # The state account holds dev + prod state for every other config — losing it
  # is unrecoverable. Make a stray destroy of this bootstrap config fail at plan.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

# Portal-side guard: a CanNotDelete lock on the state RG refuses a delete of the
# resource group (and the account/container inside it) from outside Terraform.
resource "azurerm_management_lock" "state" {
  name       = "tfstate-no-delete"
  scope      = azurerm_resource_group.state.id
  lock_level = "CanNotDelete"
  notes      = "Protects the Terraform state store for all environments."
}
