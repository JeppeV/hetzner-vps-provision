# Hetzner VPS provisioning and hardening

Version-controlled provisioning and ongoing hardening for Ubuntu 24.04 servers
on Hetzner Cloud (`hcloud`, not dedicated servers/Robot).

| Directory | Responsibility | Documentation |
| --- | --- | --- |
| `terraform/` | Reusable module: server, public IPs, firewall, backups, and secure cloud-init bootstrap | [Module setup and inputs](terraform/README.md) |
| `terraform/examples/basic/` | Runnable local Terraform consumer; provider credentials and state belong here or in your own deployment repository | [Example configuration](terraform/examples/basic/main.tf) |
| `ansible/` | Optional ongoing guest hardening and read-only verification | [Setup and usage](ansible/README.md) |

The repository root is **not** a Terraform deployment root.

## How the layers fit together

```text
Terraform apply → export inventory → Ansible harden → Ansible verify
```

Terraform works without Ansible. It creates the infrastructure and uses cloud-init
for the initial secure admin, SSH policy, and updates. Apply completion does not
mean cloud-init has finished.

Ansible maintains the running OS over SSH and waits for cloud-init to succeed.
The Terraform-to-Ansible handoff contains the server address, admin username, and
intended SSH/ingress policy, exported as `ansible_inventory`. You can supply inventory
manually instead; Ansible does not call Terraform or require its state. Neither tool automatically
invokes the other, and subsequent Ansible runs do not require a Terraform apply.

Ansible does not reboot by default. Set `baseline_reboot_if_required: true` explicitly
to let a successful hardening run reboot if Ubuntu requests it, then reconnect and
verify again. The read-only verification playbook never reboots.

Terraform owns the Hetzner firewall. Ansible adds UFW on the guest using the exported
policy, plus a journal-backed fail2ban SSH jail. Both are enabled by default in the
Ansible baseline, not in cloud-init; Terraform alone does not install them. See the
Ansible documentation for network ownership and rollout precautions.

## Get started

1. Follow the [Terraform module guide](terraform/README.md) to configure a calling
   deployment, review its plan, and provision the server. Servers, public IPv4,
   and backups incur charges.
2. Follow the [Ansible guide](ansible/README.md) to export inventory, verify SSH
   host identity, and preview/apply the baseline from Linux, macOS, or WSL2.

Module sources must target `terraform/`, not the repository root. See
[using the module from another repository](terraform/README.md#use-from-another-repository)
for provider setup and Git-source syntax.

**Rendered cloud-init changes still replace the server and destroy its OS disk.**
Keep secrets out of bootstrap inputs and Git, preserve console/rescue access,
and review the module's protection and backup limitations before destructive work.

## Reuse as a Git submodule

Keep deployment configuration in your own repository and pin this repository as a
submodule (replace the placeholder URL with the real remote):

```sh
git submodule add https://github.com/YOUR_ORG/hetzner-vps-provision.git vendor/hetzner-vps
git submodule update --init --recursive # Also run after cloning the calling repository.
```

From a Terraform root at `infra/`, use:

```hcl
module "vps" {
  source = "../vendor/hetzner-vps/terraform"

  name              = "production-app"
  server_type       = "cx23"
  location          = "fsn1"
  ssh_public_keys   = [file(pathexpand("~/.ssh/id_ed25519.pub"))]
  ssh_allowed_cidrs = ["203.0.113.10/32"] # Replace with your real public IP.
}
```

Configure the provider and state backend in `infra/`; commit its provider lockfile
and the submodule commit, never state, credentials, or private keys. Review the plan
on every submodule upgrade. For several servers, use separate module blocks or
`for_each`; keep environment-specific settings out of the submodule.

The [Ansible reuse guide](ansible/README.md#reuse-from-another-repository) shows how
to use the same checkout without copying playbooks or inventory into it.

## Verify without provisioning

From this repository's root:

```sh
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false -input=false
terraform -chdir=terraform validate
terraform -chdir=terraform test
terraform -chdir=terraform/examples/basic init -backend=false -input=false
terraform -chdir=terraform/examples/basic validate
```

Terraform tests use a mocked provider and plan-only runs. For Ansible linting,
syntax checks, and local configuration/policy tests, see
[Ansible verification](ansible/README.md#test-without-provisioning).
Neither CI workflow provisions resources or connects to guests; live boot, SSH,
and idempotence checks require an explicitly authorized test server.
