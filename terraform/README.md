# Hetzner Cloud VPS module

Reusable Terraform module for **one Ubuntu 24.04 Hetzner Cloud VPS**, its public
networking, firewall, and first-boot security configuration. This targets Hetzner
Cloud (`hcloud`), not dedicated servers/Robot.

## What is included

- Explicitly managed IPv4 and optional IPv6 primary IPs, retained across server
  replacement in the same location (`auto_delete = false`).
- A firewall attached **during server creation**: SSH only from your supplied
  CIDRs, ICMP for diagnostics/PMTU, all other ingress denied. Outbound traffic is
  unrestricted, including package downloads and DNS. Application ports are opt-in.
- A non-root, key-only SSH admin with passwordless sudo; locked root/admin
  passwords; root SSH, password authentication, and keyboard-interactive
  authentication disabled. Only the admin user can log in via SSH.
- First-boot package upgrades and daily unattended security updates, without
  automatic reboots. Schedule reboots yourself when updates require them.
- Paid automatic server backups enabled by default. Server delete/rebuild and
  primary-IP delete protection are disabled by default; opt in with
  `protection_enabled = true`. Disk growth on resize is disabled (`keep_disk = true`)
  to preserve downgrade options; deletion requests a graceful shutdown.

Public keys are installed directly by cloud-init: no private keys are generated,
uploaded, or required by Terraform, and no project-global Hetzner SSH-key records
are created. The same public key can therefore be used by multiple module instances
or repositories without duplicate-key ownership conflicts.

Cloud-init vendor-data consumption is disabled (`vendor_data.enabled = false`).
The module owns the key-only account/password policy instead of running Hetzner's
vendor-supplied root-password setup, which can use deprecated `chpasswd.list` syntax
and overwrite password locks. This skips provider vendor cloud-config and scripts,
not Hetzner datasource metadata or its network configuration. No provider-generated
root password is applied through vendor-data; use the configured admin SSH key and
retain console/rescue access.

For repeatable **ongoing OS hardening** after provisioning, use the optional
[`ansible/` playbooks](../ansible/README.md). They maintain and verify SSH policy,
password locks, unattended updates, bounded persistent logs, a UFW guest firewall,
and fail2ban SSH banning without Terraform provisioners or automatic reboots.
Terraform remains the only manager of the Hetzner firewall; the exported inventory
supplies the intended SSH/ingress policy to the guest firewall.

## Use from another repository

Requires Terraform **>= 1.7, < 2** and `hetznercloud/hcloud` **>= 1.70.2, < 2**.
Create a Hetzner Cloud project and a read/write API token. Configure the provider
in the **calling repository**, not inside this module; supply the token through
the `HCLOUD_TOKEN` environment variable or your CI secret store.

```hcl
terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.70.2, < 2.0.0"
    }
  }
}

provider "hcloud" {}

module "vps" {
  # Replace the URL/ref with this repository's real remote and a published tag
  # or immutable commit. Until published, use a relative local source instead.
  source = "git::https://github.com/YOUR_ORG/hetzner-vps-provision.git//terraform?ref=YOUR_TAG_OR_COMMIT"

  name              = "production-app"
  server_type       = "cx23"
  location          = "fsn1"
  ssh_public_keys   = [file(pathexpand("~/.ssh/id_ed25519.pub"))]
  ssh_allowed_cidrs = ["203.0.113.10/32"] # Replace with your real public IP.

  # Optional: deliberately expose HTTPS, including IPv6.
  ingress_rules = [{
    description  = "Public HTTPS"
    protocol     = "tcp"
    port         = "443"
    source_cidrs = ["0.0.0.0/0", "::/0"]
  }]

  labels = { environment = "production" }
}

output "ssh_command" {
  value = module.vps.ssh_command
}
```

The module lives in this repository's `terraform/` subdirectory, not at the
repository root. Git sources must include `//terraform` **before** `?ref=...`;
local sources must point to the `terraform/` directory. Existing callers should
update their source to a revision containing this layout and rerun `terraform init`.
Keep module/resource addresses
unchanged: this is a directory move, not a state migration, and does not change
cloud-init or require server replacement by itself. Always review the plan.

No web server or TLS certificate is installed by opening a port. Supply SSH public
keys as strings from your CI configuration when local key files are unavailable.
The documentation IPs (`203.0.113.0/24`, `2001:db8::/32`) are placeholders, not
usable management addresses. Both IPv4 and IPv6 SSH access need explicit CIDRs;
`/0` SSH ranges and additional TCP rules overlapping port 22 are rejected.
IPv4-only servers must have at least one IPv4 SSH source to avoid lockout.

Review pricing, server-type availability, location/data residency, and the plan
before applying. Servers, IPv4 addresses, and backups incur charges. This module
does not create the Hetzner account/project, token, or Terraform state backend.

```sh
terraform init
terraform plan -out=vps.tfplan
terraform apply vps.tfplan
terraform output -raw ssh_command
```

For a local working example, see [`examples/basic`](examples/basic): copy
`terraform.tfvars.example` to `terraform.tfvars`, replace the values, and run the
commands there. Commit the **calling repository's** provider lockfile. This module
repository ignores lockfiles so consumers resolve their own compatible providers.
The example keeps the server name, type, location, public-key path, and SSH sources
in `terraform.tfvars`; existing example users should add the first three from
`terraform.tfvars.example`. For a pinned local checkout, see
[Git-submodule reuse](../README.md#reuse-as-a-git-submodule).

## Inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `name` | required | Unique lowercase hostname, maximum 63 characters |
| `server_type` | required | Instance size/architecture; no implicit cost choice |
| `location` | required | Explicit location/data residency |
| `ssh_public_keys` | required | Non-empty set of OpenSSH public keys |
| `ssh_allowed_cidrs` | required | Non-empty trusted IPv4/IPv6 source CIDRs; no `/0` |
| `admin_username` | `"admin"` | Non-root SSH/sudo account |
| `ingress_rules` | `[]` | Objects with `description`, `protocol` (`tcp`/`udp`), `port`, `source_cidrs` |
| `ipv6_enabled` | `true` | Allocate and attach an IPv6 /64 |
| `backups_enabled` | `true` | Paid Hetzner automatic backups |
| `protection_enabled` | `false` | Opt-in server delete/rebuild and IP delete protection |
| `labels` | `{}` | Labels shared by all resources |
| `additional_packages` | `[]` | Extra Ubuntu packages installed on first boot |
| `bootstrap_commands` | `[]` | Extra root commands as argv lists, e.g. `[["install", "-d", "/opt/app"]]` |

Additional ingress ports accept a single port or ascending range (`8000-8010`),
not `any`. Application source CIDRs are always explicit. Before validating SSH,
bootstrap creates the root-owned `/run/sshd` runtime directory, which may not exist
yet on a socket-activated first boot. It then validates the baseline SSH configuration
and reloads the service if active or starts it if inactive. Bootstrap commands run
only afterward; they are trusted root code and can undo hardening. Bootstrap stops
on the first failed command. Shell syntax requires explicitly invoking a shell,
for example `["sh", "-ec", "your command"]`. User data is limited to 32 KiB.

Outputs: `server_id`, `server_name`, `ipv4_address`, `ipv6_address`, `ipv6_network`,
`primary_ip_ids`, `firewall_id`, `ssh_command`, and `ansible_inventory`. IPv6 outputs
are `null` when disabled. Use these to compose application-specific resources
outside this module. Forward `ansible_inventory` from the calling root to export
it with `terraform output -json ansible_inventory`.
The inventory also includes `baseline_ssh_allowed_cidrs` and `baseline_ingress_rules`
for UFW. Re-export it after rule changes. These output additions do not change
resources or cloud-init, but existing callers must record the updated outputs
through a reviewed apply before exporting them.

## Operational boundaries and gotchas

- **Apply completion is not guest readiness.** Terraform waits for Hetzner, not
  cloud-init. After SSH becomes available, run `sudo cloud-init status --wait`;
  investigate failures in `/var/log/cloud-init-output.log`. Do not deploy workloads
  until initialization succeeds. Cloud-init hardening is a first-boot operation;
  the optional [Ansible baseline](../ansible/README.md) provides repeatable ongoing
  configuration and a read-only verification playbook. Schedule runs yourself.
  `status: done` with exit code 2 is degraded, not clean success; inspect
  `sudo cloud-init status --long`. Earlier deployments may show only deprecated
  `chpasswd` warnings from vendor-data. The vendor-data bootstrap fix prevents that
  password setup on a fresh boot; it does not clear an existing run's recorded
  warnings. Do not reset cloud-init or accept all exit-code-2 results to bypass the
  Ansible readiness check.
- **Verify SSH host identity.** Obtain the host-key fingerprint through a trusted
  channel (Hetzner console/rescue) and verify it on first connection. Do not disable
  host-key checking or trust unauthenticated `ssh-keyscan` output by itself.
- **Replacement destroys the OS disk.** Changes to public keys, admin name,
  packages, commands, or any rendered cloud-init content force replacement, as do
  image/location changes. Updating the module can change user data too. No
  `ignore_changes` masks this. Rotate keys on live machines through configuration
  management when replacement is not acceptable. Do not enable
  `create_before_destroy`: a replacement cannot simultaneously share primary IPs.
  The SSH runtime-directory/startup and vendor-data fixes change rendered cloud-init
  too, so adopting them replaces an existing server; they do not repair a previously
  failed or degraded boot in place.
- **Protection is opt-in, not a plan policy.** `protection_enabled` defaults to
  `false`; set it to `true` explicitly to retain protection when upgrading from an
  earlier protected default. Existing protected resources remain protected until a
  reviewed apply updates their flags; a destroy does not apply the new default first.
  For the verified hcloud 1.70.2 resource implementations, protected server/IP deletion
  is rejected by the API. If protection is enabled, before an intentional
  destroy/replacement, first set `protection_enabled = false` and apply that change
  **alone**, then review and apply the destructive plan. Re-enable protection
  afterward only if desired. If a module update already proposes replacement, use
  the previous module/bootstrap revision for the protection-only apply first.
  Provider behavior may change; do not rely on these locks
  instead of reviewed plans, CI deletion policies, and independent backups. Even a
  rejected deletion can shut the server down first, because the provider requests
  graceful shutdown before attempting deletion.
- **Backups are not disaster recovery.** Hetzner server backups do not cover
  attached volumes and are tied to the server lifecycle. Keep off-server,
  application-consistent backups and test restores before destructive changes.
  Snapshot/export anything you must retain before deleting/replacing a server.
- **Stable IPs have limits.** IPs survive same-location server replacement, but
  full module destruction deletes them too. Location changes replace IPs. Removing
  IPv6 can require first disabling protection and will interrupt networking; server
  resizing/network changes can also cause downtime.
- **Firewall ownership stays here.** Add rules through `ingress_rules`, not a
  second firewall attachment manager. Hetzner Cloud firewalls protect public
  networking, not private-network traffic. Private networks, volumes, DNS/TLS,
  applications, monitoring, and an independent backup destination are deliberately
  caller-owned; a single public VPS does not require them. If you attach private
  networks externally, account for their traffic in the guest firewall too. The
  optional Ansible baseline applies UFW to all guest interfaces, including private
  ones; it does not manage the Hetzner firewall or its attachment.
- **Keep secrets out of bootstrap inputs.** User data is sent to Hetzner and
  persisted on the guest; commands may appear in logs/plans. Terraform state and
  saved plans must be treated as sensitive and kept in an access-controlled,
  encrypted, locking backend in the caller. Fetch runtime secrets through a
  dedicated secret-management mechanism instead.
- **Recovery requires account access.** With root/password SSH disabled, maintain
  working Hetzner console/rescue access and an independent copy of your SSH key.
  The SSH admin has full root privileges through passwordless sudo.

## Verify the module without provisioning

Run from this directory (`terraform/`), matching the Terraform CI working directory:

```sh
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
terraform test
terraform -chdir=examples/basic init -backend=false -input=false
terraform -chdir=examples/basic validate
```

Tests use Terraform's mocked provider and **plan-only** runs: no token, SSH key
files, Hetzner API calls, or paid resources are needed. Run a single test file with
`terraform test -filter=tests/security.tftest.hcl`. CI runs the same checks.
Mocked tests verify configuration, not boot-time behavior; a real deployment still
needs a guest smoke check:

```sh
sudo cloud-init status --wait
sudo /usr/sbin/sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|authenticationmethods|allowusers) '
sudo -n true
sudo passwd -S root
sudo passwd -S "$(id -un)"
systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer
```

Run these as the non-root admin. Require a zero exit code from cloud-init and locked
password status (`L`) for root and the admin. Check the expected SSH settings (`no`,
`no`, `no`, `publickey`, and your admin username), verify that an unauthorized external
source cannot reach port 22, and test your application/backup recovery separately.
No live smoke test runs in CI.
