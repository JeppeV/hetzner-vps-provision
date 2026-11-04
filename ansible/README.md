# Ongoing VPS hardening

Optional, repeatable Ansible configuration for servers created by this module.
Terraform still owns Hetzner resources; Ansible connects over SSH and manages the
guest OS. No Terraform provisioners, Hetzner credentials, or automatic deployment
hooks are required. The pinned `community.general` collection supplies UFW support.

## Baseline

- Wait for authenticated SSH, supported OS facts, passwordless sudo, and successful
  cloud-init completion before making changes. A degraded cloud-init result fails
  the run too; investigate it instead of bypassing readiness checks.
- Keep root/admin passwords locked, without replacing public keys or sudo policy.
- Maintain key-only, admin-only SSH with root login disabled. Validate syntax and
  effective policy for admin and root using the current management connection's
  addresses before reloading. Roll back a changed drop-in on validation failure.
- After an SSH configuration change, reset the persistent connection and verify
  a fresh authenticated connection. This is a safety check, not a guarantee against
  lockout: retain Hetzner console/rescue access.
- Maintain daily unattended updates using Ubuntu's configured update origins,
  without automatic reboots or a full package upgrade during the playbook run.
- Keep persistent systemd journals with a 256 MiB usage target and 512 MiB free-space
  reserve. Inspect the merged journal configuration for overriding drop-ins.
- Report `/var/run/reboot-required`; do not reboot by default. Optionally let
  `harden.yml` reboot after successful hardening/verification when Ubuntu requests
  it, then check readiness and verify again. `verify.yml` never reboots.
- Maintain UFW for IPv4 and IPv6: default-deny incoming/forwarded traffic, allow
  outgoing traffic, and install the inventory's SSH and TCP/UDP ingress rules.
  Validate that the current management source is allowed before changing anything,
  add replacement allows before pruning obsolete baseline rules, then test a fresh
  SSH connection. Never reset UFW or silently delete unrelated permissive rules.
- Maintain an SSH-only fail2ban jail using the system journal, with five failures
  within ten minutes triggering a ten-minute ban. Exempt loopback and the current
  Ansible controller. Validate the complete configuration and effective jail before
  restarting; roll back the managed file if validation fails.

This is a focused baseline, **not a CIS compliance claim**. It does not rotate
keys, create/delete accounts, choose application ports, remove arbitrary packages,
manage the Hetzner firewall, modify unrelated sysctls, configure application backups,
or deploy workloads. The SSH allowlist deliberately permits only `ansible_user`.
Agent forwarding and X11 forwarding remain disabled, matching the module bootstrap.
Match rules for other users, client addresses, or reverse-DNS names are not an
exhaustive part of the SSH checks; review custom SSH configuration separately.

## 1. Install on the controller

Use Linux, macOS, or **WSL2 on Windows**, with Python >= 3.12 and an OpenSSH client.
Terraform is only needed there if you export inventory from that environment;
manual inventory does not require Terraform. Managed hosts must be the module's
Ubuntu 24.04 servers with Python 3, cloud-init, and systemd.
On Debian/Ubuntu controllers, install `python3-venv` if creating the virtual
environment below reports that ensurepip is unavailable.

From this repository's root, in a POSIX shell:

```sh
python3 -m venv ansible/.venv
. ansible/.venv/bin/activate
python -m pip install -r ansible/requirements.txt
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-galaxy collection install -r ansible/requirements.yml
```

Use your existing SSH agent or `--private-key ~/.ssh/id_ed25519` when running
Ansible. Never put private keys, passwords, or API tokens in inventory or Git.
The controller's source IP must be permitted by Terraform's `ssh_allowed_cidrs`.
Loading a key in Windows does not necessarily load it in your WSL SSH agent.

## 2. Export inventory from the deployment root

The module exports an `ansible_inventory` object. Forward it from your **calling
Terraform root** (already included in `terraform/examples/basic/main.tf`):

```hcl
output "ansible_inventory" {
  value = module.vps.ansible_inventory
}
```

After your reviewed Terraform apply has recorded that output, export it. For the
local example, run from this repository's root:

```sh
terraform -chdir=terraform/examples/basic output -json ansible_inventory > ansible/inventory.json
```

For another consumer, replace `terraform/examples/basic` with its deployment directory.
The reusable module is in `terraform/`; neither it nor the repository root is a
deployment root. Ansible does not run Terraform or provision anything. Export
inventory again after replacement or address changes. The inventory uses the
managed IPv4 address and configured admin username, not an inferred/default login.
Generated inventory is Git-ignored.

**Existing users:** update the module, review/apply its output-only changes, and
re-export inventory before using the new baseline. UFW now requires the exported
`baseline_ssh_allowed_cidrs` and uses `baseline_ingress_rules`; old address-only
inventory fails safely before packages or firewall rules are changed. Export again
after every Terraform SSH-source or ingress change, not only address changes.

Alternatively, copy `inventory.example.yml` to `inventory.yml`, set real values,
and pass `-i inventory.yml` to every command below. Multiple servers can be listed
under `vps.hosts`; runs process one host at a time and stop the fleet on failure.

### Reuse from another repository

With this repository checked out at `vendor/hetzner-vps`, keep inventory and
environment-specific variables in the calling repository. From its root, after
installing the controller dependencies from the submodule:

```sh
baseline="$PWD/vendor/hetzner-vps/ansible"
export ANSIBLE_CONFIG="$baseline/ansible.cfg"
terraform -chdir=infra output -json ansible_inventory > inventory.json
ansible-playbook -i "$PWD/inventory.json" "$baseline/harden.yml" --check --diff
ansible-playbook -i "$PWD/inventory.json" "$baseline/harden.yml" --diff
ansible-playbook -i "$PWD/inventory.json" "$baseline/verify.yml"
```

Verify host identity as described below **before running these playbooks**. Use
`group_vars/vps.yml` beside your inventory for overrides and ignore generated
inventory in the calling repository. Always pass `-i`: the supplied configuration's
default inventory is for the local example workflow. Role-specific filters live
inside `roles/baseline/`, so they also work when the role is reused directly.

For multiple module instances, merge their host maps rather than overwriting the
inventory with each export. For example, when using `module "vps"` with `for_each`:

```hcl
output "ansible_inventory" {
  value = {
    vps = {
      hosts = merge([for instance in module.vps : instance.ansible_inventory.vps.hosts]...)
    }
  }
}
```

Use unique server names: inventory host keys must not collide. Direct role callers
must also run `tasks/preflight.yml` before the role; the supplied playbooks already
handle readiness, sequential rollout, failure handling, and optional rebooting.

## 3. Verify SSH host identity

Obtain the server's Ed25519 fingerprint through a trusted channel, for example
the Hetzner console:

```sh
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

On the controller, make an initial interactive connection using the inventory's
admin and IP, compare the presented fingerprint, and accept it **only if it
matches**. This records the key in that environment's `~/.ssh/known_hosts`.
For example, replace the username/address below with the inventory values:

```sh
ssh -o StrictHostKeyChecking=ask -o HostKeyAlgorithms=ssh-ed25519 admin@SERVER_IPV4
```

Ansible uses strict host-key checking and will not accept unknown keys for you.
`ssh-keyscan` alone is not identity verification. Following replacement at a
retained IP, verify the new key through the console before updating known_hosts.

Keep a console session available during initial hardening.

## 4. Preview, apply, and verify

```sh
cd ansible
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
ansible-inventory --graph
ansible-playbook harden.yml --check --diff
ansible-playbook harden.yml --diff
ansible-playbook verify.yml
```

Set `ANSIBLE_CONFIG` explicitly, especially for WSL repositories on Windows-mounted
filesystems: Ansible will not automatically load configuration from a world-writable
working directory. The supplied configuration enables strict host-key checking.
Review the inventory graph and use `--limit example-vps` to target one server.

Check mode still connects, waits for cloud-init, and checks sudo, but does not
validate the proposed full SSH configuration or reload/reconnect services. It is
also not a live UFW/fail2ban preview: their mutations and full configuration/runtime
checks are skipped, including when their packages have not yet been installed. It is
not a substitute for the normal run's post-change verification. `verify.yml` makes
read-only checks and does not repair drift; run `harden.yml` to reconcile it.
Do not use `--force-handlers`: failed validation must not trigger a reload.

Re-run `harden.yml` after baseline changes. An immediate second run should report
no configuration changes; refreshing an expired APT cache can still report a
change. Schedule runs yourself; installing these files creates no cron jobs or
CI access to production.

### Configuration

Override journal limits through inventory, `group_vars/vps.yml`, or an extra-vars
file. Positive sizes with `K`, `M`, or `G` suffixes are supported:

```yaml
baseline_journal_max_use: 256M
baseline_journal_keep_free: 512M
```

Keep environment-specific configuration in the calling repository when reusing
this module. Do not point several independently managed roles at the same files.

### Optional reboot after hardening

`baseline_reboot_if_required` defaults to `false`. To allow a reboot at the end of
the current hardening run, from `ansible/` with the controller environment configured:

```sh
ansible-playbook -i inventory.json harden.yml --diff \
  -e '{"baseline_reboot_if_required": true}'
```

Alternatively, set `baseline_reboot_if_required: true` in inventory or
`group_vars/vps.yml`. Use a YAML/JSON boolean: string values such as those supplied
by `-e baseline_reboot_if_required=true` are rejected before guest changes.

The opt-in is consumed only by `harden.yml`, after its baseline verification passes.
It rechecks `/var/run/reboot-required` and skips the reboot if that file is absent,
even if hardening changed files. If Ubuntu requests a reboot, Ansible reboots once,
waits for authenticated access to return (a 600-second timeout for each reboot
detection/connection-test phase, plus a 15-second post-reboot delay), then reruns the
full readiness checks and baseline verification. A failed reboot, reconnect, or
verification fails the run and stops subsequent hosts; no repair/reboot loop is used.

`--check` skips the entire reboot path. `verify.yml` remains read-only and never
reboots, even when the flag is true. Unattended-upgrades automatic rebooting stays
disabled: this flag permits a reboot only during that explicit hardening run and
does not install a scheduler or change Terraform/cloud-init. No server replacement
is needed to adopt it.

**Expect downtime and keep console/rescue access available.** Applications must be
configured to start after boot; baseline verification is not an application health
check. In CI, allow enough job time for the reboot and checks, and avoid concurrent
deployments. Updates installed later wait until your next opted-in run or other
explicit maintenance.

### UFW and fail2ban

Both are managed by default. Manual inventory must supply SSH sources and any
required ingress in the same shape as Terraform (see `inventory.example.yml`):

```yaml
baseline_ssh_allowed_cidrs: ["203.0.113.20/32"] # Your controller's real public IP.
baseline_ingress_rules:
  - protocol: tcp
    port: "443" # Ranges use Terraform syntax, e.g. "8000-8010".
    source_cidrs: ["0.0.0.0/0", "::/0"]
baseline_fail2ban_bantime: 600 # Seconds; positive integers only.
baseline_fail2ban_findtime: 600
baseline_fail2ban_maxretry: 5
baseline_fail2ban_ignore_cidrs: [] # Optional additional trusted controller CIDRs.
```

The role requires port 22 and a management IP within the SSH source CIDRs; it does
not silently open SSH to everyone or infer a permanent allowlist from a connection.
SSH `/0` sources and extra TCP rules overlapping port 22 are rejected. UFW retains
its distribution ICMP, DHCP, loopback, and established-connection rules. IPv6
filtering stays enabled even if the server has no public IPv6 allocation.

UFW filters **all interfaces**, including private ones, and denies forwarding by
default. Review private-network and routed/container networking before rollout;
UFW is not a guarantee that another tool's forwarding/NAT rules cannot bypass it.
Update intended guest ingress in inventory when different private allowances are
needed; changing a guest allow does not open the Hetzner firewall. Keep the exported
policy current. This role is not a general firewall audit of arbitrary nftables rules.

For an existing UFW installation, review `sudo ufw status numbered` from a console.
The baseline refuses unmanaged permissive rules rather than resetting/adopting them.
Migrate needed allows into inventory and explicitly remove old untagged rules before
running the baseline. Only obsolete `vps-baseline` rules are automatically removed;
unrelated deny/reject rules are retained. Do not run concurrent firewall writers.

Fail2ban uses `nftables-multiport` in its own table rather than modifying UFW's
persisted rules. UFW reconciliation therefore does not clear its bans. The nftables
package supplies the command; do **not** enable `nftables.service` with a global
ruleset that flushes UFW/fail2ban tables. Other jail definitions are left alone.
The active controller is exempt to protect automation; use
`baseline_fail2ban_ignore_cidrs` for additional trusted controllers. An attacker
sharing an exempt address is also exempt. This is not protection against valid-key
compromise. Configuration changes can restart fail2ban; unchanged runs do not.

Set `baseline_manage_ufw: false` or `baseline_manage_fail2ban: false` to leave that
component to another owner. These switches **relinquish management**: they do not
stop services, disable protection, remove packages, or remove old rules. Verification
also skips the unmanaged component.

Retain Hetzner console access during rollout. Source validation and fresh-connection
checks reduce lockout risk but cannot guarantee recovery after a broken firewall.
Schedule Ansible runs and alert on failures; none of this installs a controller-side
scheduler. Run `verify.yml` for read-only configuration, service, and jail checks.

## Configuration ownership and replacement

Cloud-init provides first-boot safety; Ansible takes ongoing ownership of:

- `/etc/ssh/sshd_config.d/00-vps-hardening.conf`
- `/etc/apt/apt.conf.d/20auto-upgrades`
- `/etc/apt/apt.conf.d/52vps-unattended-upgrades`
- `/etc/systemd/journald.conf.d/60-vps-hardening.conf` and journal storage
- Root/admin password locks and enabled update timers
- UFW defaults and `vps-baseline` user rules (not the Hetzner firewall)
- `/etc/fail2ban/jail.d/99-vps-hardening.local` and the fail2ban service

Cloud-init is not rerun on each Terraform apply. Do not rerun cloud-init manually
as a configuration-management mechanism. The Ansible files do not change rendered
user data, so adopting this baseline alone does not replace a server.

**Changes to rendered cloud-init still force server replacement and destroy its
OS disk**, including Terraform public-key, admin-name, package, and bootstrap-command
changes. This workflow does not mask those changes or bypass protection. Keep the
initial policy compatible with the ongoing role; bootstrap an existing admin
before using Ansible. This version does not implement live key rotation.

SSH drop-in backups are retained on the guest when its content changes. A failed
validation restores the previous drop-in and stops before reload; a lost connection
after reload can still require console/rescue recovery. Review conflicting earlier
SSH directives and later APT/journal drop-ins rather than disabling verification.

## Test without provisioning

From `ansible/`, with the virtual environment active:

```sh
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
python -m pip install -r requirements-dev.txt
ansible-galaxy collection install -r requirements.yml
ansible-lint --project-dir .
ansible-inventory -i inventory.example.yml --list
ansible-playbook -i inventory.example.yml harden.yml --syntax-check
ansible-playbook -i inventory.example.yml verify.yml --syntax-check
ansible-playbook -i localhost, tests/render.yml --check
ansible-playbook -i localhost, tests/reboot-check.yml --check
python -m unittest discover -s tests -p 'test_*.py'
```

CI runs these checks without credentials, network access to guests, or paid
resources. Local tests also exercise effective SSH-policy assertions with safe
and deliberately unsafe fixtures; expected failures are rescued by the test.
They cover network-policy validation, IPv4/IPv6 separation, obsolete-rule detection,
controller lockout guards, fail2ban configuration, and explicit management opt-outs.
They also check shared input validation and changed-only, check-mode-safe reconnect
guards without opening a connection.
Reboot tests exercise the boolean/marker/check-mode guards and post-verification
wiring without executing a reboot action; the local check-mode playbook requires
`--check` and verifies that even the reboot-marker read is skipped.
They do **not** prove guest boot behavior, SSH reload/firewall safety, actual banning,
live reboot/reconnection behavior, or live idempotence.
Validate those on an explicitly authorized test VPS before production rollout,
including a second hardening run, `verify.yml`, and console recovery access.
On that authorized test VPS, check `sudo ufw status verbose` and
`sudo fail2ban-client status sshd`, exercise allowed/denied connections over both
address families from separate sources, and test ban/unban from a non-exempt source.
Keep a console available; do not test bans against your only management address.
