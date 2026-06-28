data "azurerm_client_config" "current" {}

# RBAC-mode vault: data-plane access is granted via role assignments rather than
# legacy access policies. purge protection is left off so a learning scaffold can
# be torn down and recreated cleanly; soft-delete stays at the 7-day minimum.
resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id

  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  tags = var.tags
}

# The CI service principal is Owner (management plane) but RBAC data-plane access
# is separate, so grant it Secrets Officer to write the secrets below.
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "redis" {
  name         = "RedisConnection"
  value        = var.redis_connection_string
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}

resource "azurerm_key_vault_secret" "cosmos" {
  name         = "CosmosConnection"
  value        = var.cosmos_connection_string
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}
