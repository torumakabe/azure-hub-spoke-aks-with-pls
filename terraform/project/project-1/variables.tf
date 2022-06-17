variable "prefix" {
  type = string
}

variable "rg_project" {
  type = object({
    name     = string
    location = string
  })
  default = {
    name     = "rg-hs-aks-pls-project-1"
    location = "japaneast"
  }
}

variable "admin_username" {
  type      = string
  default   = "adminuser"
  sensitive = true
}

variable "rg_shared" {
  type = object({
    name     = string
    location = string
  })
  default = {
    name     = "rg-hs-aks-pls-shared"
    location = "japaneast"
  }
}

variable "vnet_shared" {
  type = object({
    id           = string
    pe_subnet_id = string
  })
}

variable "acr_shared" {
  type = object({
    id = string
    image_name = object({
      nginx        = string
      apache       = string
      grpc_greeter = string
    })
  })
}
