locals {
  tenant_id = data.azurerm_client_config.current.tenant_id
  current_client = {
    subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
    object_id       = data.azurerm_client_config.current.object_id
  }
  project_vnet = {
    base_cidr_block        = "10.0.0.0/16"
    k8s_service_cidr_block = "10.1.0.0/16"
    k8s_dns_service_ip     = "10.1.0.10"
  }
}

data "azurerm_client_config" "current" {}
