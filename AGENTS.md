# Repository context

- `terraform/` is the reusable Terraform module, not a deployment root. `ansible/` contains the optional ongoing guest baseline. Provider credentials and state backend belong to callers; `terraform/examples/basic` is the runnable local consumer.
- `terraform/versions.tf` requires Terraform >= 1.7, < 2 and hcloud >= 1.70.2, < 2; CI uses Terraform 1.16.4. Provider lockfiles are intentionally ignored, including in the example; consuming repositories should commit their own.
- Module sources must point to `terraform/` (Git URLs use `//terraform?ref=...`). Moving the source path alone does not change module/resource addresses or rendered cloud-init; do not introduce state migrations or infrastructure changes for this layout change.

## Verification without provisioning

Run from the repository root (CI runs the equivalent commands with `terraform/` as its working directory):

```sh
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false -input=false
terraform -chdir=terraform validate
terraform -chdir=terraform test
terraform -chdir=terraform/examples/basic init -backend=false -input=false
terraform -chdir=terraform/examples/basic validate
```

- Focused test command after init: `terraform -chdir=terraform test -filter=tests/security.tftest.hcl`.
- Tests use a mocked hcloud provider and plan-only runs; no API token, local SSH key files, or paid resources are needed. Do not run a real apply to verify changes without explicit authorization.
- Mocks do not verify guest boot behavior. `terraform/README.md` guest smoke checks require a real deployment; apply completion does not imply cloud-init readiness (`sudo cloud-init status --wait`).

## Bootstrap and infrastructure constraints

- Cloud-init is assembled with `yamlencode` in `terraform/cloud-init.tf`. Changes to its rendered content replace the server and destroy its OS disk; preserve this warning when changing bootstrap behavior. Do not mask user-data changes with `ignore_changes`.
- Primary IPs are separately managed with `auto_delete = false` to survive same-location server replacement, not full module destruction. Do not add `create_before_destroy`: two servers cannot share those IPs.
- Install public SSH keys through cloud-init, not per-instance Hetzner SSH-key resources: project-global key records cause ownership collisions across consumers.
- Attach the firewall through the server's `firewall_ids` at creation; do not introduce a second firewall attachment manager. Extra TCP rules, including ranges, must never include port 22; SSH sources reject `/0`, and IPv4-only servers require an IPv4 SSH source.
- Ubuntu 24.04 is intentional: bootstrap assumes apt, sudo, OpenSSH drop-ins, and systemd. Other images require explicit implementation and boot verification.
- OpenSSH uses the first matching value: keep `00-vps-hardening.conf` ahead of `50-cloud-init.conf`. Cloud-init's generated `runcmd` script lacks errexit by default; preserve `set -eu` and SSH validation/reload before caller commands.
- `bootstrap_commands` are root argv lists, not shell snippets; shell syntax requires an explicit shell. Keep secrets out of user data, logs, and plans. The user-data limit is 32 KiB in bytes, not characters (`local.user_data_bytes`).
- Protection behavior is provider-version-specific; `terraform/README.md` documents the verified hcloud 1.70.2 path: apply `protection_enabled = false` alone before intentional destroy/replacement. A rejected deletion can still shut down the server first. Never equate protection flags with Terraform `prevent_destroy`.

## Optional Ansible baseline

- `ansible/harden.yml` manages the existing Ubuntu 24.04 guest; `ansible/verify.yml` is read-only. Neither provisions resources or runs automatically from Terraform. Preserve cloud-init readiness checks, strict host-key checking, SSH validation/rollback before reload, and the fresh-connection check afterward.
- `baseline_reboot_if_required` defaults to false and must be a boolean. Only `harden.yml` may reboot, after successful baseline verification and a fresh `/var/run/reboot-required` check; check mode and `verify.yml` never reboot. Preserve the post-reboot readiness and full verification checks, fail-stop behavior, and unchanged unattended-upgrades automatic-reboot policy. Never test a real reboot without explicit authorization.
- Terraform exclusively manages the Hetzner firewall/attachment. Ansible also manages UFW on the guest using `baseline_ssh_allowed_cidrs` and `baseline_ingress_rules` exported in inventory, plus a journal-backed fail2ban SSH jail with independent nftables bans. Preserve explicit management-source validation, IPv6 filtering, new allows before obsolete-rule removal, no UFW resets, and the fresh-connection check. Never clear dynamic bans as part of UFW reconciliation. The role intentionally leaves SSH public keys, application services, and reboot scheduling alone.
- `baseline_manage_ufw` and `baseline_manage_fail2ban` default to true; false relinquishes ownership without disabling installed protection. Old address-only inventories must be re-exported before UFW can be managed. Do not enable a competing global nftables ruleset/service that flushes UFW/fail2ban tables.
- Role filters live in `ansible/roles/baseline/filter_plugins/`. Both hardening and read-only verification import `tasks/validate.yml` for input validation; keep validation before guest mutations.
- Fresh-connection checks share `tasks/reconnect.yml`. Guard its dynamic include, not `meta: reset_connection` itself: that meta action ignores `when`.
- Run from `ansible/` on Linux/WSL with `ANSIBLE_CONFIG` set explicitly: install `requirements-dev.txt` and `ansible-galaxy collection install -r requirements.yml`, run `ansible-lint --project-dir .`, syntax-check both playbooks with `-i inventory.example.yml`, run `ansible-playbook -i localhost, tests/render.yml --check` and `ansible-playbook -i localhost, tests/reboot-check.yml --check`, and `python -m unittest discover -s tests -p 'test_*.py'`. These checks do not contact a VPS. Never run hardening against a real guest without authorization.
- Keep bootstrap and ongoing ownership compatible: Ansible maintains the same SSH and APT files as cloud-init after first boot. Ansible-only changes do not alter user data; Terraform bootstrap changes still replace the server.
