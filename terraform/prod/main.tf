terraform { 
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"
    features {}
  
}

terraform {
  backend "azurerm" {
    resource_group_name   = "rg-terraform-state-dev"
    storage_account_name  = "terraformstateaccdev"
    container_name        = "tfstate"
    key                   = "terraform.tfstate"
  }
}