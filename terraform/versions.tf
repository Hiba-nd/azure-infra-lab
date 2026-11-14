terraform {
  required_version = ">= 1.17.2, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13.0"
    }
  }
}

provider "azurerm" {
  features {}

  resource_provider_registrations = "none"
}
