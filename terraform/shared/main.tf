terraform {
  required_version = "~> 1.2.3"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.10.0"
    }

    azapi = {
      source  = "azure/azapi"
      version = "~> 0.3.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.3.0"
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

provider "azapi" {}
provider "tls" {}

data "http" "my_public_ip" {
  url = "https://ipconfig.io"
}

resource "azurerm_resource_group" "shared" {
  name     = var.rg_shared.name
  location = var.rg_shared.location
}

resource "random_string" "vpngw_shared_key" {
  length  = 16
  special = false
}

// (fake) On-premises VNet

resource "azurerm_virtual_network" "onprem" {
  name                = "vnet-onprem"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  address_space       = [module.onprem_vnet_subnet_addrs.base_cidr_block]
}

module "onprem_vnet_subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.onprem_vnet.base_cidr_block
  networks = [
    {
      name     = "default"
      new_bits = 4
    },
    {
      name     = "aci",
      new_bits = 8
    },
    {
      name     = "vpngw"
      new_bits = 11
    },
  ]
}

resource "azurerm_subnet" "onprem_default" {
  name                 = "snet-onprem-default"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [module.onprem_vnet_subnet_addrs.network_cidr_blocks["default"]]
}

resource "azurerm_subnet" "onprem_aci" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.onprem_default,
  ]
  name                 = "snet-onprem-aci"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [module.onprem_vnet_subnet_addrs.network_cidr_blocks["aci"]]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }

  // Waiting for delegation
  provisioner "local-exec" {
    command = "sleep 60"
  }
}

resource "azurerm_subnet" "onprem_vpngw" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.onprem_aci,
  ]
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [module.onprem_vnet_subnet_addrs.network_cidr_blocks["vpngw"]]
}

resource "azurerm_public_ip" "onprem_vpngw" {
  name                = "pip-onprem-vpngw"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network_gateway" "onprem" {
  name                = "vpng-onprem"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location

  type = "Vpn"

  active_active = false
  enable_bgp    = false
  sku           = "VpnGw1"

  ip_configuration {
    name                          = "ipconf-onprem-vpngw"
    public_ip_address_id          = azurerm_public_ip.onprem_vpngw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.onprem_vpngw.id
  }
}

resource "azurerm_virtual_network_gateway_connection" "onprem_to_hub" {
  name                = "vcn-onprem-to-hub"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name

  type = "Vnet2Vnet"

  virtual_network_gateway_id      = azurerm_virtual_network_gateway.onprem.id
  peer_virtual_network_gateway_id = azurerm_virtual_network_gateway.hub.id

  shared_key = random_string.vpngw_shared_key.result
}

// TODO: This will be replaced with AzureRM provider once config without network profile is available
resource "azapi_resource" "onprem_resolver" {
  depends_on = [
    // workaround: wait for all subnets to avoid "VirtualNetworkNotReady" error
    azurerm_subnet.onprem_default,
    azurerm_subnet.onprem_aci,
    azurerm_subnet.onprem_vpngw
  ]
  type      = "Microsoft.ContainerInstance/containerGroups@2021-09-01"
  name      = "ci-onprem-resolver"
  location  = azurerm_resource_group.shared.location
  parent_id = azurerm_resource_group.shared.id

  body = jsonencode({
    properties = {
      ipAddress = {
        type = "Private"
        ports = [
          {
            port     = 53
            protocol = "UDP"
          }
        ]
      }
      subnetIds = [
        {
          id = azurerm_subnet.onprem_aci.id
        }
      ]
      restartPolicy = "Always"
      osType        = "Linux"

      volumes = [
        {
          name = "config"
          secret = {
            Corefile = base64encode(templatefile("${path.module}/config/coredns-onprem/Corefile.tftpl",
              {
                RESOLVER_IP = jsondecode(azapi_resource.hub_resolver.output).properties.ipAddress.ip
              }
            ))
          }
        }
      ]

      containers = [
        {
          name = "coredns"
          properties = {
            image = "coredns/coredns:1.9.3"

            resources = {
              requests = {
                cpu        = 1.0
                memoryInGB = 1.0
              }
            }

            ports = [
              {
                port     = 53
                protocol = "UDP"
              }
            ]

            command = ["/coredns", "-conf", "/config/Corefile"]

            volumeMounts = [
              {
                name      = "config"
                readOnly  = true
                mountPath = "/config"
              }
            ]
          }
        }
      ]
    }
  })

  ignore_missing_property = true
  response_export_values  = ["properties.ipAddress.ip"]
}

resource "azurerm_network_security_group" "default" {
  name                = "nsg-default"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location

  // Do not assign rules for SSH statically, use JIT
}

resource "azurerm_public_ip" "client" {
  name                = "pip-client"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  allocation_method   = "Dynamic"
}

resource "azurerm_network_interface" "client" {
  name                          = "nic-client"
  resource_group_name           = azurerm_resource_group.shared.name
  location                      = azurerm_resource_group.shared.location
  enable_accelerated_networking = true
  dns_servers                   = [jsondecode(azapi_resource.onprem_resolver.output).properties.ipAddress.ip]

  ip_configuration {
    name                          = "default"
    subnet_id                     = azurerm_subnet.onprem_default.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.client.id
  }
}

resource "azurerm_network_interface_security_group_association" "client" {
  network_interface_id      = azurerm_network_interface.client.id
  network_security_group_id = azurerm_network_security_group.default.id
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "client" {
  name                            = "vm-client"
  resource_group_name             = azurerm_resource_group.shared.name
  location                        = azurerm_resource_group.shared.location
  size                            = "Standard_D2ds_v4"
  admin_username                  = var.admin_username
  disable_password_authentication = true
  identity {
    type = "SystemAssigned"
  }
  network_interface_ids = [
    azurerm_network_interface.client.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadOnly"
    storage_account_type = "Standard_LRS"
    diff_disk_settings {
      option = "Local"
    }
    disk_size_gb = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  user_data = filebase64("${path.module}/cloud-init/vm-client/cloud-config.yaml")
}

resource "azurerm_virtual_machine_extension" "aad_ssh_login_client" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.client.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

// Hub VNet

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  address_space       = [module.hub_vnet_subnet_addrs.base_cidr_block]
}

module "hub_vnet_subnet_addrs" {
  source = "hashicorp/subnets/cidr"

  base_cidr_block = local.hub_vnet.base_cidr_block
  networks = [
    {
      name     = "default"
      new_bits = 4
    },
    {
      name     = "aci"
      new_bits = 8
    },
    {
      name     = "vpngw"
      new_bits = 11
    }
  ]
}

resource "azurerm_subnet" "hub_default" {
  name                                           = "snet-hub-default"
  resource_group_name                            = azurerm_resource_group.shared.name
  virtual_network_name                           = azurerm_virtual_network.hub.name
  address_prefixes                               = [module.hub_vnet_subnet_addrs.network_cidr_blocks["default"]]
}

resource "azurerm_subnet" "hub_aci" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.hub_default,
  ]
  name                 = "snet-hub-aci"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [module.hub_vnet_subnet_addrs.network_cidr_blocks["aci"]]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }

  // Waiting for delegation
  provisioner "local-exec" {
    command = "sleep 60"
  }
}

resource "azurerm_subnet" "hub_vpngw" {
  // workaround: operate subnets one after another
  // https://github.com/hashicorp/terraform-provider-azurerm/issues/3780
  depends_on = [
    azurerm_subnet.hub_aci,
  ]
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [module.hub_vnet_subnet_addrs.network_cidr_blocks["vpngw"]]
}

resource "azurerm_public_ip" "hub_vpngw" {
  name                = "pip-hub-vpngw"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network_gateway" "hub" {
  name                = "vpng-hub"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location

  type = "Vpn"

  active_active = false
  enable_bgp    = false
  sku           = "VpnGw1"

  ip_configuration {
    name                          = "ipconf-hub-vpngw"
    public_ip_address_id          = azurerm_public_ip.hub_vpngw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.hub_vpngw.id
  }
}

resource "azurerm_virtual_network_gateway_connection" "hub_to_onprem" {
  name                = "vcn-hub-to-onprem"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name

  type = "Vnet2Vnet"

  virtual_network_gateway_id      = azurerm_virtual_network_gateway.hub.id
  peer_virtual_network_gateway_id = azurerm_virtual_network_gateway.onprem.id

  shared_key = random_string.vpngw_shared_key.result
}

resource "azurerm_container_registry" "shared" {
  name                = "${var.prefix}acrshared"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  sku                 = "Premium"
  admin_enabled       = false

  network_rule_set = [{
    default_action = "Deny"
    ip_rule = [
      {
        action   = "Allow"
        ip_range = "${chomp(data.http.my_public_ip.body)}/32"
      }
    ]
    virtual_network = []
  }]

  // For PoC purpose.
  provisioner "local-exec" {
    command = <<-EOT
      az acr import --name ${var.prefix}acrshared --source docker.io/library/nginx:1.22 --image nginx:1.22
      az acr import --name ${var.prefix}acrshared --source docker.io/library/httpd:2.4.54-bullseye --image httpd:2.4.54-bullseye
      az acr import --name ${var.prefix}acrshared --source docker.io/torumakabe/grpc-greeter-server:0.0.2 --image grpc-greeter-server:0.0.2
    EOT
  }
}

resource "azurerm_private_dns_zone" "hub_acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.shared.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub_acr" {
  name                  = "pdnsz-link-hub-acr"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.hub_acr.name
  virtual_network_id    = azurerm_virtual_network.hub.id
}

resource "azurerm_private_endpoint" "hub_acr_shared" {
  name                = "pe-acr-shared-hub-to-mt"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  subnet_id           = azurerm_subnet.hub_default.id

  private_dns_zone_group {
    name                 = "pdnszg-acr-shared-hub-to-mt"
    private_dns_zone_ids = [azurerm_private_dns_zone.hub_acr.id]
  }

  private_service_connection {
    name                           = "pe-connection-acr-shared-hub-to-mt"
    is_manual_connection           = false
    private_connection_resource_id = azurerm_container_registry.shared.id
    subresource_names              = ["registry"]
  }
}

// TODO: This will be replaced with AzureRM provider once config without network profile is available
resource "azapi_resource" "hub_resolver" {
  depends_on = [
    // workaround: wait for all subnets to avoid "VirtualNetworkNotReady" error
    azurerm_subnet.hub_default,
    azurerm_subnet.hub_aci,
    azurerm_subnet.hub_vpngw
  ]
  type      = "Microsoft.ContainerInstance/containerGroups@2021-09-01"
  name      = "ci-hub-resolver"
  location  = azurerm_resource_group.shared.location
  parent_id = azurerm_resource_group.shared.id

  body = jsonencode({
    properties = {
      ipAddress = {
        type = "Private"
        ports = [
          {
            port     = 53
            protocol = "UDP"
          }
        ]
      }
      subnetIds = [
        {
          id = azurerm_subnet.hub_aci.id
        }
      ]
      restartPolicy = "Always"
      osType        = "Linux"

      volumes = [
        {
          name = "config"
          secret = {
            Corefile = base64encode(file("${path.module}/config/coredns-hub/Corefile"))
          }
        }
      ]

      containers = [
        {
          name = "coredns"
          properties = {
            image = "coredns/coredns:1.9.3"

            resources = {
              requests = {
                cpu        = 1.0
                memoryInGB = 1.0
              }
            }

            ports = [
              {
                port     = 53
                protocol = "UDP"
              }
            ]

            command = ["/coredns", "-conf", "/config/Corefile"]

            volumeMounts = [
              {
                name      = "config"
                readOnly  = true
                mountPath = "/config"
              }
            ]
          }
        }
      ]
    }
  })

  ignore_missing_property = true
  response_export_values  = ["properties.ipAddress.ip"]
}
