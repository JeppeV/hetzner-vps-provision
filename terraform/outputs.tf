output "server_id" {
  description = "Server ID for downstream resources such as volume attachments, DNS, or load balancer targets."
  value       = hcloud_server.this.id
}

output "server_name" {
  description = "Provisioned server name."
  value       = hcloud_server.this.name
}

output "ipv4_address" {
  description = "Public IPv4 address. Managed independently so it can survive server replacement in the same location."
  value       = hcloud_server.this.ipv4_address
}

output "ipv6_address" {
  description = "Public IPv6 host address, or null when IPv6 is disabled."
  value       = var.ipv6_enabled ? hcloud_server.this.ipv6_address : null
}

output "ipv6_network" {
  description = "Assigned public IPv6 /64, or null when IPv6 is disabled."
  value       = var.ipv6_enabled ? hcloud_primary_ip.ipv6[0].ip_network : null
}

output "primary_ip_ids" {
  description = "IDs of the managed primary IPs; ipv6 is null when disabled."
  value = {
    ipv4 = hcloud_primary_ip.ipv4.id
    ipv6 = var.ipv6_enabled ? hcloud_primary_ip.ipv6[0].id : null
  }
}

output "firewall_id" {
  description = "ID of the module-owned firewall. Manage its rules through this module, not a second attachment resource."
  value       = hcloud_firewall.this.id
}

output "ssh_command" {
  description = "SSH command using the non-root admin account. Verify the host fingerprint through a trusted channel before connecting."
  value       = "ssh ${var.admin_username}@${hcloud_server.this.ipv4_address}"
}

output "ansible_inventory" {
  description = "Ansible inventory for the optional hardening playbooks. Export from the calling root with terraform output -json ansible_inventory."
  value = {
    vps = {
      hosts = {
        (var.name) = {
          ansible_host               = hcloud_server.this.ipv4_address
          ansible_user               = var.admin_username
          baseline_ssh_allowed_cidrs = sort(tolist(var.ssh_allowed_cidrs))
          baseline_ingress_rules     = var.ingress_rules
        }
      }
    }
  }
}
