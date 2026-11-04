locals {
  ssh_hardening = <<-CONFIG
    # OpenSSH uses the first value found; load before 50-cloud-init.conf.
    PermitRootLogin no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    AllowUsers ${var.admin_username}
    X11Forwarding no
    AllowAgentForwarding no
    MaxAuthTries 3
  CONFIG

  cloud_config = {
    timezone                   = "Etc/UTC"
    disable_root               = true
    ssh_pwauth                 = false
    ssh_deletekeys             = true
    ssh_genkeytypes            = ["ed25519", "rsa"]
    package_update             = true
    package_upgrade            = true
    package_reboot_if_required = false
    packages = sort(tolist(setunion(var.additional_packages, toset([
      "sudo", "unattended-upgrades",
    ]))))

    # Own password policy here instead of consuming Hetzner's vendor password
    # setup, which can use deprecated chpasswd syntax and replace password locks.
    # This does not disable datasource metadata or network configuration.
    vendor_data = {
      enabled = false
    }

    users = [
      {
        name        = "root"
        lock_passwd = true
      },
      {
        name                = var.admin_username
        groups              = ["sudo"]
        shell               = "/bin/bash"
        lock_passwd         = true
        sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
        ssh_authorized_keys = sort([for key in var.ssh_public_keys : trimspace(key)])
      },
    ]

    write_files = [
      {
        path        = "/etc/ssh/sshd_config.d/00-vps-hardening.conf"
        owner       = "root:root"
        permissions = "0600"
        content     = local.ssh_hardening
      },
      {
        path        = "/etc/apt/apt.conf.d/20auto-upgrades"
        owner       = "root:root"
        permissions = "0644"
        content     = <<-CONFIG
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";
        CONFIG
      },
      {
        path        = "/etc/apt/apt.conf.d/52vps-unattended-upgrades"
        owner       = "root:root"
        permissions = "0644"
        content     = "Unattended-Upgrade::Automatic-Reboot \"false\";\n"
      },
    ]

    # cloud-init renders runcmd as a shell script without errexit by default.
    # Fail the whole bootstrap if hardening or any caller command fails.
    # Socket activation can leave /run/sshd absent and ssh.service inactive.
    # Prepare the runtime directory, then validate before reloading or starting SSH.
    runcmd = concat([
      "set -eu",
      ["install", "-d", "-o", "root", "-g", "root", "-m", "0755", "/run/sshd"],
      ["sh", "-ec", "/usr/sbin/sshd -t; systemctl reload-or-restart ssh"],
      ["systemctl", "enable", "--now", "apt-daily.timer", "apt-daily-upgrade.timer"],
    ], var.bootstrap_commands)
  }

  user_data        = "#cloud-config\n${yamlencode(local.cloud_config)}"
  user_data_base64 = base64encode(local.user_data)
  user_data_bytes = length(local.user_data_base64) * 3 / 4 - (
    endswith(local.user_data_base64, "==") ? 2 : endswith(local.user_data_base64, "=") ? 1 : 0
  )
}
