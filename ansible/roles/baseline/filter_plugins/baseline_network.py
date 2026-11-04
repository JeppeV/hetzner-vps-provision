"""Role-local inventory validation and UFW persisted user-rule inspection.

No DNS, third-party IP libraries, or guest access is needed by these filters.
"""

import ast
import ipaddress
import re

from ansible.errors import AnsibleFilterError


COMMENT = "vps-baseline"


def _networks(values, allow_world=False):
    if not isinstance(values, list):
        raise AnsibleFilterError("Source CIDRs must be a list.")
    result = set()
    for value in values:
        try:
            if not isinstance(value, str) or "/" not in value:
                raise ValueError("Use explicit CIDR notation.")
            network = ipaddress.ip_network(value, strict=False)
            if not allow_world and network.prefixlen == 0:
                raise ValueError("World-open /0 sources are not allowed here.")
        except ValueError as error:
            raise AnsibleFilterError(f"Invalid source CIDR {value!r}: {error}") from error
        result.add(str(network))
    return sorted(result)


def _rule(protocol, port, source):
    network = ipaddress.ip_network(source, strict=False)
    return {
        "protocol": protocol,
        "port": port,
        "source": str(network),
        "destination": "0.0.0.0/0" if network.version == 4 else "::/0",
    }


def firewall_policy(ssh_sources, ingress):
    """Normalize Terraform's policy, retaining explicit address families."""
    sources = _networks(ssh_sources)
    if not sources:
        raise AnsibleFilterError("Supply baseline_ssh_allowed_cidrs before managing UFW; re-export inventory.")
    rules = [_rule("tcp", "22", source) for source in sources]
    if not isinstance(ingress, list):
        raise AnsibleFilterError("baseline_ingress_rules must be a list.")
    for item in ingress:
        if not isinstance(item, dict) or item.get("protocol") not in ("tcp", "udp"):
            raise AnsibleFilterError("Ingress rules must specify tcp or udp.")
        port = item.get("port")
        if not isinstance(port, str) or not re.fullmatch(r"[1-9][0-9]{0,4}(-[1-9][0-9]{0,4})?", port):
            raise AnsibleFilterError("Use a numeric port or ascending range, not shell syntax or 'any'.")
        first, last = int(port.split("-")[0]), int(port.split("-")[-1])
        if not 1 <= first <= last <= 65535:
            raise AnsibleFilterError("Ports must be an ascending range within 1-65535.")
        if item["protocol"] == "tcp" and first <= 22 <= last:
            raise AnsibleFilterError("Manage TCP port 22 only through baseline_ssh_allowed_cidrs.")
        sources = _networks(item.get("source_cidrs"), allow_world=True)
        if not sources:
            raise AnsibleFilterError("Each ingress rule needs explicit source CIDRs.")
        for source in sources:
            rule = _rule(item["protocol"], port.replace("-", ":"), source)
            if rule not in rules:
                rules.append(rule)
    return rules


def address_allowed(address, sources):
    try:
        client = ipaddress.ip_address(address)
        return any(client in ipaddress.ip_network(source) for source in _networks(sources))
    except ValueError as error:
        raise AnsibleFilterError(f"Invalid management address: {address!r}") from error


def fail2ban_ignore_sources(address, sources):
    try:
        controller = ipaddress.ip_address(address)
    except ValueError as error:
        raise AnsibleFilterError("Invalid fail2ban controller address.") from error
    networks = [ipaddress.ip_network(value) for value in _networks(sources)]
    networks += [ipaddress.ip_network("127.0.0.0/8"), ipaddress.ip_network("::1/128"),
                 ipaddress.ip_network(controller)]
    # Avoid controller-dependent configuration churn when it is already covered.
    return sorted({str(network) for network in networks if not any(
        network.version == other.version and network != other and network.subnet_of(other)
        for other in networks
    )})


def fail2ban_policy(dump):
    """Inspect fail2ban-client -d without evaluating executable Python."""
    policy = {"actions": [], "ignored_sources": []}
    try:
        for line in dump.splitlines():
            if not line.startswith("["):
                continue
            command = ast.literal_eval(line)
            if command[:2] == ["add", "sshd"]:
                policy["backend"] = command[2]
            elif command[:2] == ["set", "sshd"]:
                name, *values = command[2:]
                if name in ("bantime", "findtime", "maxretry"):
                    policy[name] = int(values[0])
                elif name == "addaction":
                    policy["actions"].append(values[0])
                elif name == "addignoreip":
                    policy["ignored_sources"].extend(str(ipaddress.ip_network(value, strict=False)) for value in values)
    except (ValueError, SyntaxError, TypeError, IndexError) as error:
        raise AnsibleFilterError("Could not inspect the effective fail2ban SSH jail.") from error
    policy["ignored_sources"] = sorted(set(policy["ignored_sources"]))
    return policy


def fail2ban_runtime_sources(output):
    try:
        return sorted({str(ipaddress.ip_network(value, strict=False)) for value in
                       re.findall(r"(?m)^[|`]- (\S+)$", output)})
    except ValueError as error:
        raise AnsibleFilterError("Could not inspect running fail2ban exemptions.") from error


def ufw_rules(content):
    """Read Ubuntu 24.04 UFW tuple records, without changing bans or raw rules.

    Unmanaged permissive rules are reported, never silently adopted or deleted.
    Deny/reject records (including fail2ban rules from an older setup) are retained.
    """
    managed, unmanaged = [], []
    for line in content.splitlines():
        if not line.startswith("### tuple ###"):
            continue
        fields, _, encoded_comment = line.removeprefix("### tuple ###").strip().partition(" comment=")
        parts = fields.split()
        try:
            comment = bytes.fromhex(encoded_comment).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as error:
            raise AnsibleFilterError("Malformed UFW rule comment; inspect the guest firewall.") from error
        if len(parts) < 6:
            raise AnsibleFilterError("Malformed UFW rule tuple; inspect the guest firewall.")
        if comment != COMMENT:
            if parts[0] not in ("deny", "reject"):
                unmanaged.append(line)
            continue
        if (len(parts) != 7 or parts[0] != "allow" or parts[1] not in ("tcp", "udp")
                or parts[4] != "any" or parts[6] != "in"
                or not re.fullmatch(r"[0-9]{1,5}(:[0-9]{1,5})?", parts[2])):
            raise AnsibleFilterError("Unexpected vps-baseline UFW rule; inspect it before proceeding.")
        try:
            rule = _rule(parts[1], parts[2], parts[5])
            if ipaddress.ip_network(parts[3], strict=False) != ipaddress.ip_network(rule["destination"]):
                raise ValueError("Unexpected destination.")
        except ValueError as error:
            raise AnsibleFilterError("Invalid vps-baseline UFW rule addresses.") from error
        if rule not in managed:
            managed.append(rule)
    return {"managed": managed, "unmanaged": unmanaged}


class FilterModule:
    def filters(self):
        return {
            "baseline_firewall_policy": firewall_policy,
            "baseline_address_allowed": address_allowed,
            "baseline_source_cidrs": _networks,
            "baseline_ufw_rules": ufw_rules,
            "baseline_fail2ban_ignore_sources": fail2ban_ignore_sources,
            "baseline_fail2ban_policy": fail2ban_policy,
            "baseline_fail2ban_runtime_sources": fail2ban_runtime_sources,
        }
