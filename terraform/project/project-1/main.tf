terraform {
  required_version = "~> 1.2.3"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.10.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.3.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.11"
    }
  }
}

provider "azurerm" {
  use_oidc = true
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

resource "azurerm_resource_group" "project" {
  name     = var.rg_project.name
  location = var.rg_project.location
}

resource "azurerm_virtual_network" "project" {
  name                = "vnet-project"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  address_space       = [module.project_vnet_subnet_addrs.base_cidr_block]
}

module "project_vnet_subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.project_vnet.base_cidr_block
  networks = [
    {
      name     = "default"
      new_bits = 2
    },
    {
      name     = "aks"
      new_bits = 2
    },
    {
      name     = "agw"
      new_bits = 8
    },
    {
      name     = "pls"
      new_bits = 8
    }
  ]
}

resource "azurerm_subnet" "project_default" {
  name                                           = "snet-project-default"
  resource_group_name                            = azurerm_resource_group.project.name
  virtual_network_name                           = azurerm_virtual_network.project.name
  address_prefixes                               = [module.project_vnet_subnet_addrs.network_cidr_blocks["default"]]
}

resource "azurerm_subnet" "project_aks" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.project_default,
  ]
  name                                          = "snet-project-aks"
  resource_group_name                           = azurerm_resource_group.project.name
  virtual_network_name                          = azurerm_virtual_network.project.name
  address_prefixes                              = [module.project_vnet_subnet_addrs.network_cidr_blocks["aks"]]
}

resource "azurerm_subnet" "project_agw" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.project_aks,
  ]
  name                 = "snet-project-agw"
  resource_group_name  = azurerm_resource_group.project.name
  virtual_network_name = azurerm_virtual_network.project.name
  address_prefixes     = [module.project_vnet_subnet_addrs.network_cidr_blocks["agw"]]
}

resource "azurerm_subnet" "project_pls" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.project_agw,
  ]
  name                                          = "snet-project-pls"
  resource_group_name                           = azurerm_resource_group.project.name
  virtual_network_name                          = azurerm_virtual_network.project.name
  address_prefixes                              = [module.project_vnet_subnet_addrs.network_cidr_blocks["pls"]]
}

resource "azurerm_private_dns_zone" "project_acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.project.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "project_acr" {
  name                  = "pdnsz-link-prj1-acr"
  resource_group_name   = azurerm_resource_group.project.name
  private_dns_zone_name = azurerm_private_dns_zone.project_acr.name
  virtual_network_id    = azurerm_virtual_network.project.id
}

resource "azurerm_private_endpoint" "project_acr_shared" {
  name                = "pe-acr-shared-prj1-to-mt"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  subnet_id           = azurerm_subnet.project_default.id

  private_dns_zone_group {
    name                 = "pdnszg-acr-shared-prj1-to-mt"
    private_dns_zone_ids = [azurerm_private_dns_zone.project_acr.id]
  }

  private_service_connection {
    name                           = "pe-connection-acr-shared-prj1-to-mt"
    is_manual_connection           = false
    private_connection_resource_id = var.acr_shared.id
    subresource_names              = ["registry"]
  }
}

resource "azurerm_user_assigned_identity" "project_aks_cplane" {
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  name                = "mi-aks-cplane-prj1"
}

resource "azurerm_role_assignment" "contributor_project_aks_cplane_to_aks_subnet" {
  scope                = azurerm_subnet.project_aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.project_aks_cplane.principal_id

  // Waiting for Azure AD preparation
  provisioner "local-exec" {
    command = "sleep 30"
  }
}

resource "azurerm_kubernetes_cluster" "project" {
  depends_on = [
    azurerm_role_assignment.contributor_project_aks_cplane_to_aks_subnet,
  ]
  name                    = "${var.prefix}-aks-prj1"
  node_resource_group     = "${azurerm_resource_group.project.name}-node"
  resource_group_name     = azurerm_resource_group.project.name
  location                = azurerm_resource_group.project.location
  kubernetes_version      = "1.23.5"
  private_cluster_enabled = true
  dns_prefix              = "${var.prefix}-aks-prj1"
  private_dns_zone_id     = "System"

  default_node_pool {
    name            = "default"
    node_count      = 3
    vnet_subnet_id  = azurerm_subnet.project_aks.id
    vm_size         = "Standard_D2ds_v4"
    os_disk_type    = "Ephemeral"
    os_disk_size_gb = 30
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.project_aks_cplane.id]
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "calico"
    network_mode   = "transparent"
    service_cidr   = local.project_vnet.k8s_service_cidr_block
    dns_service_ip = local.project_vnet.k8s_dns_service_ip
    // Unnecessary it now practically, but for passing validation of terraform
    docker_bridge_cidr = "172.17.0.1/16"
  }
}

resource "azurerm_role_assignment" "project_aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.project.kubelet_identity.0.object_id
  role_definition_name             = "AcrPull"
  scope                            = var.acr_shared.id
  skip_service_principal_aad_check = true
}

resource "azurerm_private_dns_zone" "project_aks_api" {
  name                = join(".", slice(split(".", azurerm_kubernetes_cluster.project.private_fqdn), 1, 6))
  resource_group_name = var.rg_shared.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "project_aks_api" {
  name                  = "pdnsz-link-prj1-aks-api"
  resource_group_name   = var.rg_shared.name
  private_dns_zone_name = azurerm_private_dns_zone.project_aks_api.name
  virtual_network_id    = var.vnet_shared.id
}

resource "azurerm_private_endpoint" "project_aks_api" {
  name                = "pe-aks-api-hub-to-prj1"
  resource_group_name = var.rg_shared.name
  location            = var.rg_shared.location
  subnet_id           = var.vnet_shared.pe_subnet_id

  private_service_connection {
    name                           = "pe-connection-aks-api-prj1-to-mt"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_kubernetes_cluster.project.id
    subresource_names              = ["management"]
  }
}

resource "azurerm_private_dns_a_record" "pe_project_aks_api" {
  name                = split(".", azurerm_kubernetes_cluster.project.private_fqdn).0
  zone_name           = azurerm_private_dns_zone.project_aks_api.name
  resource_group_name = var.rg_shared.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.project_aks_api.private_service_connection.0.private_ip_address]
}


provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.project.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.project.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.project.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.project.kube_config.0.cluster_ca_certificate)
}

resource "time_sleep" "wait_aks_api_pe" {
  depends_on = [
    azurerm_private_endpoint.project_aks_api,
    azurerm_private_dns_zone_virtual_network_link.project_aks_api,
    azurerm_private_dns_a_record.pe_project_aks_api,
  ]

  create_duration = "30s"
}

resource "kubernetes_deployment_v1" "nginx" {
  depends_on = [
    time_sleep.wait_aks_api_pe,
    azurerm_role_assignment.project_aks_acr_pull,
    azurerm_private_endpoint.project_aks_api,
    azurerm_private_dns_zone_virtual_network_link.project_aks_api,
    azurerm_private_dns_a_record.pe_project_aks_api,
  ]
  metadata {
    name = "nginx"
    labels = {
      app = "nginx"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "nginx"
      }
    }

    template {
      metadata {
        labels = {
          app = "nginx"
        }
      }

      spec {
        container {
          image = var.acr_shared.image_name.nginx
          name  = "nginx"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "nginx" {
  depends_on = [
    time_sleep.wait_aks_api_pe,
    azurerm_role_assignment.project_aks_acr_pull,
    azurerm_private_endpoint.project_aks_api,
    azurerm_private_dns_zone_virtual_network_link.project_aks_api,
    azurerm_private_dns_a_record.pe_project_aks_api,
  ]
  metadata {
    name = "nginx"
    annotations = {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    }
  }
  spec {
    selector = {
      app = kubernetes_deployment_v1.nginx.metadata.0.labels.app
    }
    port {
      port        = 8080
      target_port = 80
    }

    type = "LoadBalancer"
  }
}

resource "kubernetes_deployment_v1" "apache" {
  depends_on = [
    time_sleep.wait_aks_api_pe,
    azurerm_role_assignment.project_aks_acr_pull,
    azurerm_private_endpoint.project_aks_api,
    azurerm_private_dns_zone_virtual_network_link.project_aks_api,
    azurerm_private_dns_a_record.pe_project_aks_api,
  ]
  metadata {
    name = "apache"
    labels = {
      app = "apache"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "apache"
      }
    }

    template {
      metadata {
        labels = {
          app = "apache"
        }
      }

      spec {
        container {
          image = var.acr_shared.image_name.apache
          name  = "apache"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "apache" {
  depends_on = [
    time_sleep.wait_aks_api_pe,
    azurerm_role_assignment.project_aks_acr_pull,
    azurerm_private_endpoint.project_aks_api,
    azurerm_private_dns_zone_virtual_network_link.project_aks_api,
    azurerm_private_dns_a_record.pe_project_aks_api,
  ]
  metadata {
    name = "apache"
    annotations = {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    }
  }
  spec {
    selector = {
      app = kubernetes_deployment_v1.apache.metadata.0.labels.app
    }
    port {
      port        = 8080
      target_port = 80
    }

    type = "LoadBalancer"
  }
}

resource "kubernetes_deployment_v1" "grpc_greeter" {
  depends_on = [
    time_sleep.wait_aks_api_pe,
    azurerm_role_assignment.project_aks_acr_pull,
    azurerm_private_endpoint.project_aks_api,
    azurerm_private_dns_zone_virtual_network_link.project_aks_api,
    azurerm_private_dns_a_record.pe_project_aks_api,
  ]
  metadata {
    name = "grpc-greeter"
    labels = {
      app = "grpc-greeter"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "grpc-greeter"
      }
    }

    template {
      metadata {
        labels = {
          app = "grpc-greeter"
        }
      }

      spec {
        container {
          image = var.acr_shared.image_name.grpc_greeter
          name  = "grpc-greeter"

          port {
            container_port = 50051
          }
        }
      }
    }
  }
}

resource "random_id" "pls_grpc_greeter" {
  byte_length = 32
}


resource "kubernetes_service_v1" "grpc_greeter" {
  depends_on = [
    time_sleep.wait_aks_api_pe,
    azurerm_role_assignment.project_aks_acr_pull,
    azurerm_private_endpoint.project_aks_api,
    azurerm_private_dns_zone_virtual_network_link.project_aks_api,
    azurerm_private_dns_a_record.pe_project_aks_api,
  ]
  metadata {
    name = "grpc-greeter"
    annotations = {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
      "service.beta.kubernetes.io/azure-pls-create"             = "true"
      "service.beta.kubernetes.io/azure-pls-name"               = "pls-${random_id.pls_grpc_greeter.id}"
    }
  }
  spec {
    selector = {
      app = kubernetes_deployment_v1.grpc_greeter.metadata.0.labels.app
    }
    port {
      port        = 50051
      target_port = 50051
    }

    type = "LoadBalancer"
  }
}

resource "azurerm_public_ip" "agw_prj" {
  name                = "pip-agw-prj1"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "project" {
  name                = "agw-prj1"
  resource_group_name = azurerm_resource_group.project.name
  location            = azurerm_resource_group.project.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "gw-ip"
    subnet_id = azurerm_subnet.project_agw.id
  }

  // For outbound only
  frontend_ip_configuration {
    name                 = "fe-ip-ob"
    public_ip_address_id = azurerm_public_ip.agw_prj.id
  }

  frontend_port {
    name = "fe-port"
    port = 80
  }

  frontend_ip_configuration {
    name                            = "fe-ip"
    subnet_id                       = azurerm_subnet.project_agw.id
    private_ip_address_allocation   = "Static"
    private_ip_address              = cidrhost(module.project_vnet_subnet_addrs.network_cidr_blocks["agw"], 11)
    private_link_configuration_name = "pls-config"
  }

  private_link_configuration {
    name = "pls-config"
    ip_configuration {
      name                          = "pls-ip-config"
      subnet_id                     = azurerm_subnet.project_pls.id
      private_ip_address_allocation = "Dynamic"
      primary                       = true
    }
  }

  backend_address_pool {
    name         = "aks-svc-nginx-be-ap"
    ip_addresses = [kubernetes_service_v1.nginx.status.0.load_balancer.0.ingress.0.ip]
  }

  backend_address_pool {
    name         = "aks-svc-apache-be-ap"
    ip_addresses = [kubernetes_service_v1.apache.status.0.load_balancer.0.ingress.0.ip]
  }

  backend_http_settings {
    name                  = "aks-svc-nginx-be-hs"
    cookie_based_affinity = "Disabled"
    host_name             = "nginx.${azurerm_private_dns_zone.project_internal_poc.name}"
    path                  = "/"
    port                  = 8080
    protocol              = "Http"
    request_timeout       = 10
    connection_draining {
      enabled           = true
      drain_timeout_sec = 10
    }
  }

  backend_http_settings {
    name                  = "aks-svc-apache-be-hs"
    cookie_based_affinity = "Disabled"
    host_name             = "apache.${azurerm_private_dns_zone.project_internal_poc.name}"
    path                  = "/"
    port                  = 8080
    protocol              = "Http"
    request_timeout       = 10
    connection_draining {
      enabled           = true
      drain_timeout_sec = 10
    }
  }

  http_listener {
    name                           = "aks-svc-nginx-http-ln"
    frontend_ip_configuration_name = "fe-ip"
    frontend_port_name             = "fe-port"
    protocol                       = "Http"
    host_name                      = "nginx.${azurerm_private_dns_zone.project_internal_poc.name}"
  }

  http_listener {
    name                           = "aks-svc-apache-http-ln"
    frontend_ip_configuration_name = "fe-ip"
    frontend_port_name             = "fe-port"
    protocol                       = "Http"
    host_name                      = "apache.${azurerm_private_dns_zone.project_internal_poc.name}"
  }

  request_routing_rule {
    name                       = "aks-svc-nginx-rule"
    rule_type                  = "Basic"
    http_listener_name         = "aks-svc-nginx-http-ln"
    backend_address_pool_name  = "aks-svc-nginx-be-ap"
    backend_http_settings_name = "aks-svc-nginx-be-hs"
    priority                   = 100
  }

  request_routing_rule {
    name                       = "aks-svc-apache-rule"
    rule_type                  = "Basic"
    http_listener_name         = "aks-svc-apache-http-ln"
    backend_address_pool_name  = "aks-svc-apache-be-ap"
    backend_http_settings_name = "aks-svc-apache-be-hs"
    priority                   = 200
  }
}

resource "azurerm_private_endpoint" "agw_hub_project" {
  name                = "pe-agw-hub-to-prj1"
  resource_group_name = var.rg_shared.name
  location            = var.rg_shared.location
  subnet_id           = var.vnet_shared.pe_subnet_id


  private_service_connection {
    name                           = "pe-connection-agw-hub-to-prj1"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_application_gateway.project.id
    subresource_names              = ["fe-ip"]
  }
}

resource "azurerm_private_endpoint" "grpc_greeter_project" {
  depends_on = [
    kubernetes_service_v1.grpc_greeter,
  ]
  name                = "pe-grpc-greeter-hub-to-prj1"
  resource_group_name = var.rg_shared.name
  location            = var.rg_shared.location
  subnet_id           = var.vnet_shared.pe_subnet_id


  private_service_connection {
    name                           = "pe-connection-grpc-greeter-hub-to-prj1"
    is_manual_connection           = false
    private_connection_resource_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${azurerm_kubernetes_cluster.project.node_resource_group}/providers/Microsoft.Network/privateLinkServices/pls-${random_id.pls_grpc_greeter.id}"
  }
}

resource "azurerm_private_dns_zone" "project_internal_poc" {
  name                = "project1.internal.poc"
  resource_group_name = var.rg_shared.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub_project" {
  name                  = "pdnsz-link-hub-project1"
  resource_group_name   = var.rg_shared.name
  private_dns_zone_name = azurerm_private_dns_zone.project_internal_poc.name
  virtual_network_id    = var.vnet_shared.id
}

resource "azurerm_private_dns_a_record" "aks_svc_nginx" {
  name                = "nginx"
  zone_name           = azurerm_private_dns_zone.project_internal_poc.name
  resource_group_name = var.rg_shared.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.agw_hub_project.private_service_connection.0.private_ip_address]
}

resource "azurerm_private_dns_a_record" "aks_svc_apache" {
  name                = "apache"
  zone_name           = azurerm_private_dns_zone.project_internal_poc.name
  resource_group_name = var.rg_shared.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.agw_hub_project.private_service_connection.0.private_ip_address]
}

resource "azurerm_private_dns_a_record" "aks_svc_grpc_greeter" {
  name                = "grpc-greeter"
  zone_name           = azurerm_private_dns_zone.project_internal_poc.name
  resource_group_name = var.rg_shared.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.grpc_greeter_project.private_service_connection.0.private_ip_address]
}
