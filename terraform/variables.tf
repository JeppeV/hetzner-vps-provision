variable "name" {
  description = "Unique server name within the Hetzner project; also used to name dependent resources."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.name) <= 63 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.name))
    error_message = "Use a lowercase hostname of 1-63 letters, digits, or hyphens, without leading/trailing hyphens."
  }
}

variable "server_type" {
  description = "Hetzner Cloud server type available in the chosen location (for example, cx23). Determines cost and architecture."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.server_type)) > 0
    error_message = "Choose a non-empty server type explicitly."
  }
}

variable "location" {
  description = "Hetzner Cloud location (for example, fsn1, nbg1, or hel1). Choose explicitly for data residency."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "Choose a non-empty location explicitly."
  }
}

variable "ssh_public_keys" {
  description = "OpenSSH public keys installed for the admin user by cloud-init. Never provide private keys."
  type        = set(string)
  nullable    = false

  validation {
    condition = length(var.ssh_public_keys) > 0 && alltrue([
      for key in var.ssh_public_keys : can(regex(
        "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/]+={0,2}( [^\r\n]+)?$",
        trimspace(key)
      ))
    ])
    error_message = "Supply at least one single-line OpenSSH public key (Ed25519, RSA, ECDSA, or a supported security key)."
  }
}

variable "ssh_allowed_cidrs" {
  description = "Explicit IPv4/IPv6 CIDRs allowed to reach SSH on port 22. World-open /0 ranges are rejected."
  type        = set(string)
  nullable    = false

  validation {
    condition = length(var.ssh_allowed_cidrs) > 0 && alltrue([
      for cidr in var.ssh_allowed_cidrs : can(cidrhost(cidr, 0)) && try(tonumber(split("/", cidr)[1]) > 0, false)
    ])
    error_message = "Supply at least one valid SSH source CIDR; /0 ranges are not permitted. Use your public IP /32 or IPv6 /128."
  }
}

variable "admin_username" {
  description = "Non-root SSH administrator with passwordless sudo."
  type        = string
  default     = "admin"
  nullable    = false

  validation {
    condition = can(regex("^[a-z][a-z0-9_-]{0,30}$", var.admin_username)) && !contains([
      "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp", "proxy",
      "www-data", "backup", "list", "irc", "nobody", "systemd-network", "systemd-resolve", "messagebus", "sshd",
    ], var.admin_username)
    error_message = "Use a non-system username of 1-31 lowercase letters, digits, underscores, or hyphens, starting with a letter."
  }
}

variable "ingress_rules" {
  description = "Additional TCP/UDP ingress. Sources must be explicit; TCP port 22 must be managed only through ssh_allowed_cidrs."
  type = list(object({
    description  = string
    protocol     = string
    port         = string
    source_cidrs = set(string)
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for rule in var.ingress_rules : contains(["tcp", "udp"], rule.protocol)
    ])
    error_message = "Additional ingress supports only tcp and udp. ICMP is already allowed for network diagnostics and PMTU."
  }

  validation {
    condition = alltrue([
      for rule in var.ingress_rules : can(regex("^[1-9][0-9]{0,4}(-[1-9][0-9]{0,4})?$", rule.port)) && try(
        tonumber(split("-", rule.port)[0]) <= 65535 &&
        tonumber(reverse(split("-", rule.port))[0]) <= 65535 &&
        tonumber(split("-", rule.port)[0]) <= tonumber(reverse(split("-", rule.port))[0]),
        false
      )
    ])
    error_message = "Ports must be between 1 and 65535, either a single port or an ascending range such as 8000-8010; 'any' is not allowed."
  }

  validation {
    condition = alltrue([
      for rule in var.ingress_rules : rule.protocol != "tcp" || try(
        tonumber(split("-", rule.port)[0]) > 22 || tonumber(reverse(split("-", rule.port))[0]) < 22,
        false
      )
    ])
    error_message = "Additional TCP rules must not include SSH port 22, including within a port range. Use ssh_allowed_cidrs instead."
  }

  validation {
    condition = alltrue([
      for rule in var.ingress_rules : length(rule.source_cidrs) > 0 && alltrue([
        for cidr in rule.source_cidrs : can(cidrhost(cidr, 0))
      ])
    ])
    error_message = "Every additional ingress rule needs at least one valid source CIDR. Public application access requires an explicit /0."
  }
}

variable "ipv6_enabled" {
  description = "Allocate and attach a managed public IPv6 /64 in addition to the managed IPv4 address."
  type        = bool
  default     = true
  nullable    = false
}

variable "backups_enabled" {
  description = "Enable paid Hetzner automatic server backups. These are not an independent application backup strategy."
  type        = bool
  default     = true
  nullable    = false
}

variable "protection_enabled" {
  description = "Opt in to server delete/rebuild protection and primary-IP delete protection (disabled by default). See README before replacement or destruction."
  type        = bool
  default     = false
  nullable    = false
}

variable "labels" {
  description = "Hetzner labels applied to the server, firewall, and primary IPs."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "additional_packages" {
  description = "Additional Ubuntu packages installed during first boot. Changing these replaces the server."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for package in var.additional_packages : can(regex("^[a-z0-9][a-z0-9+.-]*$", package))])
    error_message = "Use plain Ubuntu package names, not shell commands or package-manager options."
  }
}

variable "bootstrap_commands" {
  description = "Additional first-boot commands, each as an argv list, run as root after SSH hardening. Do not embed secrets. Changes replace the server."
  type        = list(list(string))
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for command in var.bootstrap_commands : try(length(command) > 0 && length(trimspace(command[0])) > 0, false)])
    error_message = "Each bootstrap command must be a non-empty argv list with a non-empty executable."
  }
}
