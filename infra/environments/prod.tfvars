environment = "prod"
location    = "eastus"

# Prod runs the real stores; their secrets live in Key Vault and reach the app as
# @Microsoft.KeyVault(...) references resolved via the managed identity.
enable_redis    = true
enable_cosmos   = true
enable_keyvault = true
