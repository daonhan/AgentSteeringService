# Backend config for the dev environment.
# Fill `storage_account_name` with the value emitted by `infra/bootstrap`
# (terraform output state_storage_account_name).
resource_group_name  = "rg-agentsteering-tfstate"
storage_account_name = "REPLACE_WITH_BOOTSTRAP_OUTPUT"
container_name       = "tfstate"
key                  = "dev.tfstate"
