"""Offline policy/reconciliation tests. Never invoke UFW, nft, SSH, or fail2ban."""

import importlib.util
from pathlib import Path
import unittest

from ansible.errors import AnsibleFilterError


SPEC = importlib.util.spec_from_file_location(
    "baseline_network", Path(__file__).resolve().parents[1] / "roles/baseline/filter_plugins/baseline_network.py"
)
network = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(network)


def ingress(port="443", protocol="tcp", sources=None):
    return [{"protocol": protocol, "port": port, "source_cidrs": ["0.0.0.0/0"] if sources is None else sources}]


def tuple_line(source="203.0.113.20", port="22", comment="vps-baseline", action="allow", destination="0.0.0.0/0"):
    return f"### tuple ### {action} tcp {port} {destination} any {source} in comment={comment.encode().hex()}\n"


class NetworkPolicyTests(unittest.TestCase):
    def test_normalizes_and_deduplicates_sources(self):
        rules = network.firewall_policy(["203.0.113.20/24", "203.0.113.0/24"], [])
        self.assertEqual(len(rules), 1)
        self.assertEqual(rules[0]["source"], "203.0.113.0/24")

    def test_requires_explicit_ssh_sources(self):
        for sources in ([], None, "203.0.113.20/32", ["not-a-cidr"], ["203.0.113.20"]):
            with self.subTest(sources=sources), self.assertRaises(AnsibleFilterError):
                network.firewall_policy(sources, [])

    def test_rejects_every_world_open_ssh_form(self):
        for source in ("0.0.0.0/0", "::/0", "192.0.2.1/0", "2001:db8::1/0"):
            with self.subTest(source=source), self.assertRaises(AnsibleFilterError):
                network.firewall_policy([source], [])

    def test_keeps_world_open_application_rules_family_specific(self):
        rules = network.firewall_policy(["203.0.113.20/32"], ingress(sources=["0.0.0.0/0", "::/0"]))
        self.assertEqual(rules[1]["destination"], "0.0.0.0/0")
        self.assertEqual(rules[2]["destination"], "::/0")

    def test_accepts_ipv6_management(self):
        self.assertTrue(network.address_allowed("2001:db8::20", ["2001:db8::/64"]))
        self.assertFalse(network.address_allowed("2001:db8:1::20", ["2001:db8::/64"]))
        self.assertFalse(network.address_allowed("203.0.113.20", ["2001:db8::/64"]))

    def test_detects_management_source_outside_policy(self):
        self.assertTrue(network.address_allowed("203.0.113.20", ["203.0.113.0/24"]))
        self.assertFalse(network.address_allowed("198.51.100.20", ["203.0.113.0/24"]))

    def test_rejects_application_ssh_bypasses(self):
        for port in ("22", "1-22", "22-443", "1-65535"):
            with self.subTest(port=port), self.assertRaises(AnsibleFilterError):
                network.firewall_policy(["203.0.113.20/32"], ingress(port=port))

    def test_udp_22_does_not_open_ssh(self):
        self.assertEqual(network.firewall_policy(["203.0.113.20/32"], ingress(port="22", protocol="udp"))[1]["protocol"], "udp")

    def test_rejects_invalid_ports_and_sources(self):
        cases = [ingress(port=port) for port in ("0", "65536", "9000-8000", "any", "443; reboot", "-22", None)]
        cases += [ingress(protocol="icmp"), ingress(sources=[]), ingress(sources=["bad"])]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(AnsibleFilterError):
                network.firewall_policy(["203.0.113.20/32"], case)

    def test_converts_ranges(self):
        self.assertEqual(network.firewall_policy(["203.0.113.20/32"], ingress(port="8000-8010"))[1]["port"], "8000:8010")

    def test_exempts_controller_and_loopback_only_by_default(self):
        self.assertEqual(network.fail2ban_ignore_sources("203.0.113.20", []),
                         ["127.0.0.0/8", "203.0.113.20/32", "::1/128"])

    def test_explicit_controller_subnet_prevents_configuration_churn(self):
        self.assertEqual(network.fail2ban_ignore_sources("203.0.113.20", ["203.0.113.0/24"]),
                         network.fail2ban_ignore_sources("203.0.113.21", ["203.0.113.0/24"]))

    def test_rejects_world_open_fail2ban_exemptions(self):
        with self.assertRaises(AnsibleFilterError):
            network.fail2ban_ignore_sources("203.0.113.20", ["0.0.0.0/0"])

    def test_reads_family_specific_ufw_records(self):
        rules = network.ufw_rules(tuple_line() + tuple_line(source="::/0", port="443", destination="::/0"))
        self.assertEqual(len(rules["managed"]), 2)
        self.assertEqual(rules["managed"][0]["source"], "203.0.113.20/32")
        self.assertEqual(rules["managed"][1]["destination"], "::/0")
        self.assertEqual(rules["unmanaged"], [])

    def test_preserves_deny_rules_but_reports_unmanaged_allows(self):
        content = tuple_line(comment="other", action="deny") + tuple_line(comment="other", port="80")
        rules = network.ufw_rules(content)
        self.assertEqual(rules["managed"], [])
        self.assertEqual(len(rules["unmanaged"]), 1)

    def test_obsolete_rules_can_be_removed_without_resetting_bans(self):
        old = network.ufw_rules(tuple_line() + tuple_line(port="443"))["managed"]
        desired = network.firewall_policy(["203.0.113.20/32"], [])
        self.assertEqual([rule["port"] for rule in old if rule not in desired], ["443"])

    def test_rejects_malformed_or_repurposed_managed_ufw_rules(self):
        for content in (tuple_line(action="allow_log"), tuple_line(destination="192.0.2.0/24"),
                        tuple_line(port="any"), "### tuple ### allow tcp\n"):
            with self.subTest(content=content), self.assertRaises(AnsibleFilterError):
                network.ufw_rules(content)

    def test_reads_effective_fail2ban_configuration(self):
        commands = [["add", "sshd", "systemd"], ["set", "sshd", "bantime", "600"],
                    ["set", "sshd", "findtime", "600"], ["set", "sshd", "maxretry", 5],
                    ["set", "sshd", "addaction", "nftables-multiport"],
                    ["set", "sshd", "addignoreip", "127.0.0.0/8", "::1", "203.0.113.20"]]
        policy = network.fail2ban_policy("\n".join(repr(command) for command in commands))
        self.assertEqual(policy["backend"], "systemd")
        self.assertEqual(policy["maxretry"], 5)
        self.assertEqual(policy["bantime"], 600)
        self.assertEqual(policy["actions"], ["nftables-multiport"])
        self.assertEqual(policy["ignored_sources"], network.fail2ban_ignore_sources("203.0.113.20", []))

    def test_disabled_or_overridden_jail_is_not_reported_as_correct(self):
        self.assertNotIn("backend", network.fail2ban_policy("['start', 'other']"))
        self.assertEqual(network.fail2ban_policy("['add', 'sshd', 'polling']")["backend"], "polling")

    def test_normalizes_running_fail2ban_exemptions(self):
        output = "These IP addresses/networks are ignored:\n|- 127.0.0.0/8\n|- ::1\n`- 203.0.113.20"
        self.assertEqual(network.fail2ban_runtime_sources(output), network.fail2ban_ignore_sources("203.0.113.20", []))


if __name__ == "__main__":
    unittest.main()
