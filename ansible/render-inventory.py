import argparse
import json
import re
import sys
from ipaddress import IPv4Address


def read_output(outputs, name):
    output = outputs.get(name)
    if (
        not isinstance(output, dict)
        or output.get("sensitive") is not False
        or output.get("type") != "string"
        or not isinstance(output.get("value"), str)
    ):
        raise ValueError(f"{name} must be a non-sensitive Terraform string output")
    return output["value"]


def main():
    parser = argparse.ArgumentParser(
        description="Read terraform output -json from stdin and write an Ansible inventory."
    )
    parser.parse_args()

    try:
        outputs = json.load(sys.stdin)
    except ValueError:
        parser.exit(1, "error: expected JSON from terraform output -json\n")
    if not isinstance(outputs, dict):
        parser.exit(1, "error: expected a Terraform outputs object\n")

    try:
        address = read_output(outputs, "public_ip")
        username = read_output(outputs, "admin_username")
    except ValueError as error:
        parser.exit(1, f"error: {error}\n")

    try:
        IPv4Address(address)
    except ValueError:
        parser.exit(1, "error: public_ip must be an IPv4 address\n")
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
        parser.exit(1, "error: admin_username must be a Linux account name\n")

    host = {"ansible_host": address, "ansible_user": username}
    inventory = {"all": {"children": {"lab": {"hosts": {"lab-vm": host}}}}}
    print(json.dumps(inventory, indent=2))


if __name__ == "__main__":
    main()
