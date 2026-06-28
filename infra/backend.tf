terraform {
  # Partial backend config. Concrete values (storage account, blob key) come from
  # `-backend-config=environments/<env>.backend.hcl` so dev and prod state are
  # separated by blob key and never selected by accident.
  backend "azurerm" {}
}
