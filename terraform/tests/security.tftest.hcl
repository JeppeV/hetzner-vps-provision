mock_provider "hcloud" {}

variables {
  name              = "test-vps"
  server_type       = "cx23"
  location          = "fsn1"
  ssh_public_keys   = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test-only"]
  ssh_allowed_cidrs = ["203.0.113.10/32", "2001:db8::10/128"]
}

run "secure_defaults" {
  command = plan

  assert {
    condition     = hcloud_server.this.backups
    error_message = "Backups must default to enabled independently of protection."
  }

  assert {
    condition     = !hcloud_server.this.delete_protection && !hcloud_server.this.rebuild_protection && !hcloud_primary_ip.ipv4.delete_protection && !hcloud_primary_ip.ipv6[0].delete_protection
    error_message = "Server delete/rebuild protection and both primary-IP delete protections must default to disabled."
  }

  assert {
    condition     = hcloud_server.this.keep_disk && hcloud_server.this.shutdown_before_deletion
    error_message = "Keep the existing disk size when resizing and request graceful shutdown on deletion."
  }

  assert {
    condition     = !hcloud_primary_ip.ipv4.auto_delete && !hcloud_primary_ip.ipv6[0].auto_delete
    error_message = "Managed primary IPs must not be implicitly deleted with the server."
  }

  assert {
    condition     = length(hcloud_firewall.this.rule) == 2 && alltrue([for rule in hcloud_firewall.this.rule : rule.direction == "in"])
    error_message = "Only SSH and ICMP should be admitted by default; egress must remain unrestricted."
  }

  assert {
    condition = alltrue([
      for rule in hcloud_firewall.this.rule : rule.protocol != "tcp" || (
        rule.port == "22" && toset(rule.source_ips) == var.ssh_allowed_cidrs
      )
    ])
    error_message = "SSH must only be allowed from the supplied CIDRs."
  }

  assert {
    condition     = length(hcloud_server.this.firewall_ids) == 1
    error_message = "The firewall must be attached as part of server creation."
  }

  assert {
    condition     = local.cloud_config.disable_root && !local.cloud_config.ssh_pwauth && alltrue([for user in local.cloud_config.users : user.lock_passwd])
    error_message = "Root SSH and password logins must be disabled, and user passwords locked."
  }

  assert {
    condition     = local.cloud_config.users[1].ssh_authorized_keys == sort(tolist(var.ssh_public_keys))
    error_message = "Public keys must reach the non-root admin user, not just root."
  }

  assert {
    condition = alltrue([
      for setting in ["PermitRootLogin no", "PasswordAuthentication no", "KbdInteractiveAuthentication no", "AuthenticationMethods publickey", "AllowUsers admin"] :
      strcontains(local.ssh_hardening, setting)
    ])
    error_message = "Effective SSH policy must require public keys and restrict access to the admin account."
  }

  assert {
    condition     = contains(local.cloud_config.packages, "unattended-upgrades") && !local.cloud_config.package_reboot_if_required
    error_message = "Install automatic security updates without unattended reboots."
  }

  assert {
    condition     = yamldecode(local.user_data).users[1].name == "admin" && yamldecode(local.user_data).ssh_pwauth == false
    error_message = "Rendered cloud-init must be valid YAML and preserve the security settings."
  }
}

run "key_only_bootstrap_without_vendor_data" {
  command = plan

  assert {
    condition     = try(yamldecode(hcloud_server.this.user_data).vendor_data.enabled, true) == false
    error_message = "Rendered cloud-init must disable vendor-data consumption so provider password setup cannot override the module's key-only baseline or emit legacy chpasswd warnings."
  }

  assert {
    condition = (
      !can(yamldecode(hcloud_server.this.user_data).chpasswd) &&
      !can(yamldecode(hcloud_server.this.user_data).password) &&
      alltrue([for user in yamldecode(hcloud_server.this.user_data).users : user.lock_passwd])
    )
    error_message = "Keep passwords locked through user configuration, without adding password-setting directives or deprecated-key overrides."
  }
}

run "protection_opt_in" {
  command = plan

  variables {
    protection_enabled = true
  }

  assert {
    condition     = hcloud_server.this.delete_protection && hcloud_server.this.rebuild_protection && hcloud_primary_ip.ipv4.delete_protection && hcloud_primary_ip.ipv6[0].delete_protection
    error_message = "Opting in must enable server delete/rebuild protection and both primary-IP delete protections."
  }
}

run "ipv4_only_with_application_rule" {
  command = plan

  variables {
    ipv6_enabled = false
    ingress_rules = [{
      description  = "Public HTTPS"
      protocol     = "tcp"
      port         = "443"
      source_cidrs = ["0.0.0.0/0"]
    }]
  }

  assert {
    condition     = length(hcloud_primary_ip.ipv6) == 0 && output.ipv6_address == null && output.ipv6_network == null
    error_message = "IPv4-only servers must not allocate IPv6 resources or advertise IPv6 outputs."
  }

  assert {
    condition     = !one(hcloud_server.this.public_net).ipv6_enabled && length(hcloud_firewall.this.rule) == 3
    error_message = "Disable IPv6 explicitly and append only the requested application rule."
  }

  assert {
    condition = length([
      for rule in hcloud_firewall.this.rule : rule if rule.protocol == "tcp" && rule.port == "443" && toset(rule.source_ips) == toset(["0.0.0.0/0"])
    ]) == 1
    error_message = "The application rule must preserve the explicitly requested port and sources."
  }

  assert {
    condition     = output.ansible_inventory.vps.hosts["test-vps"].baseline_ingress_rules == var.ingress_rules
    error_message = "Guest firewall inventory must preserve the cloud firewall ingress policy."
  }
}

run "ssh_bootstrap_order" {
  command = plan

  assert {
    condition = jsonencode(yamldecode(hcloud_server.this.user_data).runcmd) == jsonencode([
      "set -eu",
      ["install", "-d", "-o", "root", "-g", "root", "-m", "0755", "/run/sshd"],
      ["sh", "-ec", "/usr/sbin/sshd -t; systemctl reload-or-restart ssh"],
      ["systemctl", "enable", "--now", "apt-daily.timer", "apt-daily-upgrade.timer"],
    ])
    error_message = "Rendered bootstrap must create the root-owned SSH runtime directory before validation, then reload active SSH or start inactive SSH, stopping on any failure."
  }
}

run "bootstrap_extensions" {
  command = plan

  variables {
    admin_username      = "operator"
    additional_packages = ["curl", "sudo"]
    bootstrap_commands  = [["install", "-d", "/opt/app"]]
  }

  assert {
    condition     = local.cloud_config.users[1].name == "operator" && strcontains(local.ssh_hardening, "AllowUsers operator")
    error_message = "The configured admin must match the SSH allowlist."
  }

  assert {
    condition     = length(local.cloud_config.packages) == 3 && contains(local.cloud_config.packages, "curl")
    error_message = "Merge and deduplicate package dependencies without dropping baseline packages."
  }

  assert {
    condition     = jsonencode(slice(yamldecode(local.user_data).runcmd, 4, length(local.cloud_config.runcmd))) == jsonencode(var.bootstrap_commands)
    error_message = "Caller commands must remain argv lists appended after SSH setup and update-timer activation."
  }

  assert {
    condition = output.ansible_inventory.vps.hosts["test-vps"].ansible_user == "operator" && (
      keys(output.ansible_inventory.vps.hosts) == ["test-vps"] &&
      keys(output.ansible_inventory.vps.hosts["test-vps"]) == ["ansible_host", "ansible_user", "baseline_ingress_rules", "baseline_ssh_allowed_cidrs"] &&
      toset(output.ansible_inventory.vps.hosts["test-vps"].baseline_ssh_allowed_cidrs) == var.ssh_allowed_cidrs
    )
    error_message = "Ansible inventory must expose connection and guest-firewall policy fields, preserving the admin and SSH sources."
  }
}

run "reject_empty_ssh_sources" {
  command = plan
  variables {
    ssh_allowed_cidrs = []
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "reject_world_open_ipv4_ssh" {
  command = plan
  variables {
    ssh_allowed_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "reject_world_open_ipv6_ssh" {
  command = plan
  variables {
    ssh_allowed_cidrs = ["::/0"]
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "reject_noncanonical_world_open_ssh" {
  command = plan
  variables {
    ssh_allowed_cidrs = ["192.0.2.1/0"]
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "reject_invalid_cidr" {
  command = plan
  variables {
    ssh_allowed_cidrs = ["not-a-cidr"]
  }
  expect_failures = [var.ssh_allowed_cidrs]
}

run "reject_ipv6_only_sources_without_ipv6" {
  command = plan
  variables {
    ipv6_enabled      = false
    ssh_allowed_cidrs = ["2001:db8::10/128"]
  }
  expect_failures = [hcloud_server.this]
}

run "reject_missing_keys" {
  command = plan
  variables {
    ssh_public_keys = []
  }
  expect_failures = [var.ssh_public_keys]
}

run "reject_private_key" {
  command = plan
  variables {
    ssh_public_keys = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
  }
  expect_failures = [var.ssh_public_keys]
}

run "reject_root_admin" {
  command = plan
  variables {
    admin_username = "root"
  }
  expect_failures = [var.admin_username]
}

run "reject_application_ssh_bypass" {
  command = plan
  variables {
    ingress_rules = [{
      description  = "Unsafe SSH range"
      protocol     = "tcp"
      port         = "1-443"
      source_cidrs = ["0.0.0.0/0", "::/0"]
    }]
  }
  expect_failures = [var.ingress_rules]
}

run "reject_invalid_port_range" {
  command = plan
  variables {
    ingress_rules = [{
      description  = "Invalid range"
      protocol     = "udp"
      port         = "9000-8000"
      source_cidrs = ["203.0.113.0/24"]
    }]
  }
  expect_failures = [var.ingress_rules]
}

run "reject_direct_ssh_bypass" {
  command = plan
  variables {
    ingress_rules = [{
      description  = "Unsafe SSH"
      protocol     = "tcp"
      port         = "22"
      source_cidrs = ["::/0"]
    }]
  }
  expect_failures = [var.ingress_rules]
}

run "reject_out_of_bounds_port" {
  command = plan
  variables {
    ingress_rules = [{
      description  = "Out of bounds"
      protocol     = "udp"
      port         = "65536"
      source_cidrs = ["203.0.113.0/24"]
    }]
  }
  expect_failures = [var.ingress_rules]
}

run "reject_missing_application_sources" {
  command = plan
  variables {
    ingress_rules = [{
      description  = "Missing sources"
      protocol     = "tcp"
      port         = "443"
      source_cidrs = []
    }]
  }
  expect_failures = [var.ingress_rules]
}

run "reject_empty_bootstrap_command" {
  command = plan
  variables {
    bootstrap_commands = [[]]
  }
  expect_failures = [var.bootstrap_commands]
}

run "reject_oversized_cloud_init" {
  command = plan
  variables {
    bootstrap_commands = [["echo", join("", [for i in range(1024) : "abcdefghijklmnopqrstuvwxyz0123456789"])]]
  }
  expect_failures = [hcloud_server.this]
}
