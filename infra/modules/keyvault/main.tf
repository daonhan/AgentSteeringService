data "azurerm_client_config" "current" {}

# RBAC-mode vault: data-plane access is granted via role assignments rather than
# legacy access policies. Prod-hardening (Phase 9): purge protection is on so secrets
# cannot be hard-deleted, and network ACLs deny by default with only an Azure-services
# bypass so the vault is not openly reachable. (This vault is provisioned only in prod;
# dev uses in-memory fallbacks and no vault.)
resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id

  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  # Deny-default with Azure-services bypass. NOTE: a non-Azure deployer (e.g. a
  # GitHub-hosted runner) writing the secrets below must be allowed in via an
  # ip_rules entry, a self-hosted/Azure runner, or a private endpoint — an operator
  # step, since the runner address is environment-specific.
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

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
