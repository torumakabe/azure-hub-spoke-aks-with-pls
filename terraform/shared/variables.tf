variable "prefix" {
  type = string
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

variable "admin_username" {
  type      = string
  default   = "adminuser"
  sensitive = true
}
