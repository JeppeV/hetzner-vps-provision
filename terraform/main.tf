resource "hcloud_primary_ip" "ipv4" {
  name              = "${var.name}-ipv4"
  location          = var.location
  type              = "ipv4"
  auto_delete       = false
  delete_protection = var.protection_enabled
  labels            = var.labels
}

resource "hcloud_primary_ip" "ipv6" {
  count = var.ipv6_enabled ? 1 : 0

  name              = "${var.name}-ipv6"
  location          = var.location
  type              = "ipv6"
  auto_delete       = false
  delete_protection = var.protection_enabled
  labels            = var.labels
}

resource "hcloud_firewall" "this" {
  name   = "${var.name}-firewall"
  labels = var.labels

  rule {
    description = "SSH from trusted sources only"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = sort(tolist(var.ssh_allowed_cidrs))
  }

  rule {
    description = "ICMP for diagnostics and path MTU discovery"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = var.ipv6_enabled ? ["0.0.0.0/0", "::/0"] : ["0.0.0.0/0"]
  }

  dynamic "rule" {
    for_each = var.ingress_rules
    content {
      description = rule.value.description
      direction   = "in"
      protocol    = rule.value.protocol
      port        = rule.value.port
      source_ips  = sort(tolist(rule.value.source_cidrs))
    }
  }

  # With no outbound rules, Hetzner permits all egress and established replies.
}

resource "hcloud_server" "this" {
  name        = var.name
  server_type = var.server_type
  location    = var.location
  image       = "ubuntu-24.04"
  labels      = var.labels

  user_data = local.user_data

  # Attach at creation, not through a later firewall_attachment resource.
  firewall_ids = [hcloud_firewall.this.id]

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ipv4.id
    ipv6_enabled = var.ipv6_enabled
    ipv6         = var.ipv6_enabled ? hcloud_primary_ip.ipv6[0].id : null
  }

  backups                  = var.backups_enabled
  delete_protection        = var.protection_enabled
  rebuild_protection       = var.protection_enabled
  keep_disk                = true
  shutdown_before_deletion = true

  lifecycle {
    precondition {
      condition     = var.ipv6_enabled || anytrue([for cidr in var.ssh_allowed_cidrs : can(cidrnetmask(cidr))])
      error_message = "IPv4-only servers need at least one IPv4 SSH source CIDR; IPv6-only sources would lock you out."
    }

    precondition {
      condition     = local.user_data_bytes <= 32768
      error_message = "Cloud-init user data exceeds Hetzner's 32 KiB limit. Reduce additional packages or bootstrap commands."
    }
  }
}
