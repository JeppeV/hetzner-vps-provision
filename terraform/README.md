# Hetzner Cloud VPS module

One Ubuntu 24.04 VPS with managed public IPs, a creation-time firewall, paid backups,
key-only admin SSH, first-boot upgrades, and daily security updates. No automatic
reboots. Optional [Ansible](../ansible/README.md) maintains the running guest.

## Use from another repository

Requires Terraform **>= 1.7, < 2** and hcloud **>= 1.70.2, < 2**. Create a Hetzner
Cloud project/token and export `HCLOUD_TOKEN`. In your deployment root:

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
  source = "git::https://github.com/JeppeV/hetzner-vps-provision.git//terraform?ref=YOUR_COMMIT"

  name              = "production-app"
  server_type       = "cx23"
  location          = "fsn1"
  ssh_public_keys   = [file(pathexpand("~/.ssh/id_ed25519.pub"))]
  ssh_allowed_cidrs = ["203.0.113.10/32"] # Replace with your real public IP.
}
```

Replace `YOUR_COMMIT` with a pinned revision. Local/submodule sources must also
target `terraform/`, not the repository root; see [submodule setup](../README.md#reuse-as-a-git-submodule).
Keep credentials and an encrypted, locking state backend in the caller; commit its
provider lockfile, never state or secrets. Servers, IPv4, and backups incur charges.

```sh
terraform init
terraform plan -out=vps.tfplan
terraform apply vps.tfplan
```

For a local deployment, use [examples/basic](examples/basic): copy
`terraform.tfvars.example` to `terraform.tfvars` and replace all values.

## Configuration

See [variables.tf](variables.tf) for inputs and [outputs.tf](outputs.tf) for outputs,
including addresses, resource IDs, `ssh_command`, and `ansible_inventory`.
Defaults: admin `admin`, IPv6/backups enabled, deletion protection disabled.

- SSH sources must be explicit CIDRs, never `/0`; IPv4-only servers need an IPv4 source.
- `ingress_rules` accepts TCP/UDP ports or ranges (`8000-8010`), explicit source CIDRs,
  and a description. Extra TCP rules cannot include port 22. Opening a port installs no service.
- `bootstrap_commands` are trusted root argv lists, run after SSH validation; failures
  stop bootstrap. Shell syntax needs an explicit shell, e.g. `["sh", "-ec", "command"]`.
  Keep secrets out of user data/logs/plans; user data is limited to **32 KiB in bytes**.

## Safety

- **Cloud-init changes replace the server and destroy its OS disk**, including changes
  to keys, admin name, packages, commands, or module bootstrap. Ansible-only changes do not.
  Do not hide user-data changes or add `create_before_destroy`: primary IPs cannot be shared.
- **Apply completion is not guest readiness.** Require `sudo cloud-init status --wait`
  to exit zero; exit 2 is degraded. Inspect `status --long` and `/var/log/cloud-init-output.log`;
  do not reset cloud-init to bypass failures.
- **Verify SSH fingerprints through the Hetzner console/rescue.** Keep recovery access
  and a copy of your key. Root/password SSH is disabled; the admin has passwordless sudo.
  Cloud-init disables vendor-data password setup, not datasource networking.
- **Protection is not `prevent_destroy`.** With hcloud 1.70.2, first apply
  `protection_enabled = false` **alone** before intentional replacement/destroy
  (use the previous module revision if necessary). Even rejected deletion can shut
  down the server first. Review plans; provider behavior may change.
- IPs survive same-location server replacement, **not module destruction**. Location
  changes replace IPs; resizing/network changes can cause downtime. `keep_disk = true`
  prevents automatic disk growth during resize.
- Server backups exclude attached volumes and are tied to the server lifecycle.
  Keep independent, application-consistent backups and test restores.
- Terraform alone owns the Hetzner firewall/attachment; manage rules here. It protects
  public networking, not private networks. Applications, DNS/TLS, volumes, and monitoring
  remain caller-owned. Ansible UFW also filters private interfaces.

## Verify the module without provisioning

[CI checks](../.github/workflows/terraform.yml) format, validate, and test the module
and example with mocked, plan-only runs: no token, API calls, or paid resources.

Live smoke checks require an authorized deployment: require cloud-init exit zero,
inspect `sudo sshd -T` for key-only/admin-only SSH, check `sudo -n true`, locked (`L`)
passwords with `sudo passwd -S USER`, and enabled update timers with
`systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer`.
Test denied SSH sources and independent backup restores separately.
