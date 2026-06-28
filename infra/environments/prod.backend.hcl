# Backend config for the prod environment.
# Same state storage account as dev (created once by infra/bootstrap); state is
# separated from dev only by the blob key below, so the two environments can
# never select each other's state by accident.
# Fill `storage_account_name` with the value emitted by `infra/bootstrap`
# (terraform output state_storage_account_name).
resource_group_name  = "rg-agentsteering-tfstate"
storage_account_name = "REPLACE_WITH_BOOTSTRAP_OUTPUT"
container_name       = "tfstate"
key                  = "prod.tfstate"
