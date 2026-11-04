# Ongoing VPS hardening

Optional Ubuntu 24.04 guest baseline over SSH: locked passwords, key-only admin SSH,
daily security updates, bounded persistent logs, UFW, and journal-backed fail2ban.
Terraform owns Hetzner resources; Ansible does not provision, rotate keys, deploy
applications, or run automatically. This is not a CIS compliance claim.

## Setup

Use Linux, macOS, or WSL2 with Python >= 3.12 and OpenSSH. From `ansible/`:

```sh
python3 -m venv .venv
. .venv/bin/activate
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
python -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

Set `ANSIBLE_CONFIG` explicitly, especially on Windows-mounted WSL filesystems.
Use an SSH agent or `--private-key`; never store private keys or tokens in inventory.

## Inventory

Forward the module output from your **calling Terraform root**:

```hcl
output "ansible_inventory" {
  value = module.vps.ansible_inventory
}
```

After a reviewed apply, export it (from `ansible/`, for the local example):

```sh
terraform -chdir=../terraform/examples/basic output -json ansible_inventory > inventory.json
```

Re-export after address, admin, SSH-source, or ingress changes. Old address-only
inventories lack required firewall policy. Alternatively, edit a copy of
[inventory.example.yml](inventory.example.yml) and pass `-i inventory.yml` to commands.

## Run

First obtain `sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` through the Hetzner
console. Compare it with the initial SSH prompt and accept **only a match**:

```sh
ssh -o StrictHostKeyChecking=ask -o HostKeyAlgorithms=ssh-ed25519 admin@SERVER_IPV4 true
ansible-inventory --graph
ansible-playbook harden.yml --check --diff
ansible-playbook harden.yml --diff
ansible-playbook verify.yml
```

Replace the admin/address with inventory values. Strict host-key checking remains
enabled; `ssh-keyscan` alone is not verification. Reverify keys after replacement.
Keep console/rescue access; use `--limit HOST` to narrow a run. Hosts run sequentially
and failures stop rollout.

Both playbooks require a non-root admin, passwordless sudo, and successful cloud-init.
SSH changes are validated before reload, rolled back on validation failure, and tested
with a fresh connection. Do not use `--force-handlers` or bypass readiness checks.
Check mode still connects but does **not** validate/reload proposed SSH or preview live
UFW/fail2ban changes. `verify.yml` is read-only; `harden.yml` repairs drift.

## Reuse from another repository

After installing dependencies, from the calling repository's root:

```sh
baseline="$PWD/vendor/hetzner-vps/ansible"
export ANSIBLE_CONFIG="$baseline/ansible.cfg"
terraform -chdir=infra output -json ansible_inventory > inventory.json
ansible-playbook -i "$PWD/inventory.json" "$baseline/harden.yml" --check --diff
```

Verify host identity first. Drop `--check` to apply; use `verify.yml` to verify.
Keep inventory and `group_vars/vps.yml` in the caller, ignore generated inventory,
and always pass `-i`. For `module.vps` with `for_each`, merge host maps with
`merge([for v in module.vps : v.ansible_inventory.vps.hosts]...)` under `vps.hosts`;
server names must be unique. Direct role callers must run `tasks/preflight.yml` first.

## Configuration and safety

Override [role defaults](roles/baseline/defaults/main.yml) in inventory/group vars.
Journal defaults are 256 MiB usage and 512 MiB free-space reserve (`K`/`M`/`G` sizes).

- **Reboots default to off.** Set `baseline_reboot_if_required: true` as a YAML/JSON
  boolean, not a string. Only `harden.yml` may reboot, after successful verification
  and a fresh `/var/run/reboot-required` check; it then reconnects and repeats readiness
  and verification. Check mode and `verify.yml` never reboot. Unattended-upgrades
  automatic rebooting stays disabled. Expect downtime; schedule maintenance yourself.
- UFW/fail2ban management defaults to on. UFW requires port 22 and your controller IP
  within `baseline_ssh_allowed_cidrs`; `/0` SSH sources and extra TCP port-22 rules fail.
  `baseline_ingress_rules` uses Terraform's shape. New allows precede obsolete-rule
  removal; IPv6 filtering stays enabled. UFW denies incoming/forwarded traffic on **all
  interfaces**: review private/container networking before rollout.
- Existing untagged permissive UFW rules cause failure. Migrate needed allows into
  inventory and remove old rules explicitly with console access. Only obsolete
  `vps-baseline` rules are removed; no UFW reset or dynamic-ban clearing occurs.
- Fail2ban exempts loopback and the controller; use `baseline_fail2ban_ignore_cidrs`
  for other trusted sources. Shared exempt addresses are also exempt. Independent
  nftables bans survive UFW reconciliation; do not enable a competing global
  `nftables.service` ruleset that flushes them. Avoid concurrent firewall writers.
- `baseline_manage_ufw: false` / `baseline_manage_fail2ban: false` relinquish ownership
  and skip verification; they do **not** disable installed protection.
- Ansible maintains the bootstrap SSH/APT policy without rerunning cloud-init.
  **Rendered cloud-init changes still replace the server and destroy its OS disk**;
  Ansible-only changes do not. Public keys and application services remain caller-owned.

## Test without provisioning

[CI](../.github/workflows/ansible.yml) runs lint, syntax checks, local configuration,
and Python tests. No guest access or real reboot; unsafe fixtures fail and are rescued.
Live boot, reload/firewall safety, banning, reboot recovery, and idempotence still
require an authorized test VPS. Keep a console available, run hardening twice and
verification, inspect `ufw status verbose` / `fail2ban-client status sshd`, and test
allowed/denied sources over both IP families. Never test bans against your only access.
