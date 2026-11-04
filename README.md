# Hetzner VPS provisioning and hardening

Reusable Ubuntu 24.04 VPS provisioning on Hetzner Cloud.

- [Terraform](terraform/README.md): server, public IPs, firewall, backups, key-only SSH, and security updates.
- [Optional Ansible](ansible/README.md): ongoing SSH/update hardening, bounded logs, UFW, fail2ban, and read-only verification.
- [Runnable example](terraform/examples/basic/main.tf): copy `terraform.tfvars.example` to `terraform.tfvars` and configure it.

## Reuse as a Git submodule

```sh
git submodule add https://github.com/JeppeV/hetzner-vps-provision.git vendor/hetzner-vps
```

Point your module source at `vendor/hetzner-vps/terraform` relative to your deployment
root, not this repository's root. Keep deployment config in the caller and credentials
and state out of Git. See [Ansible reuse](ansible/README.md#reuse-from-another-repository).

**Cloud-init changes replace the server and destroy its OS disk.** Review plans,
keep secrets out of user data, and retain console/rescue access. Apply completion
does not mean cloud-init is ready; reboots are not automatic by default.

Offline checks: [Terraform](terraform/README.md#verify-the-module-without-provisioning)
and [Ansible](ansible/README.md#test-without-provisioning). No VPS required.
