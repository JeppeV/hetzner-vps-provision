terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.70.2, < 2.0.0"
    }
  }
}

# Reads HCLOUD_TOKEN from the environment; no credentials belong in the module.
provider "hcloud" {}

variable "name" {
  description = "Unique server name within the Hetzner project."
  type        = string
}

variable "server_type" {
  description = "Hetzner Cloud server type; choose explicitly for cost and architecture."
  type        = string
}

variable "location" {
  description = "Hetzner Cloud location; choose explicitly for data residency."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to an existing OpenSSH PUBLIC key on the machine running Terraform."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "Trusted SSH source addresses in CIDR form. Replace the documentation address before applying."
  type        = set(string)
}

module "vps" {
  source = "../.."

  name              = var.name
  server_type       = var.server_type
  location          = var.location
  ssh_public_keys   = [file(pathexpand(var.ssh_public_key_path))]
  ssh_allowed_cidrs = var.ssh_allowed_cidrs

  labels = {
    environment = "example"
  }
}

output "ssh_command" {
  value = module.vps.ssh_command
}

output "ansible_inventory" {
  value = module.vps.ansible_inventory
}
