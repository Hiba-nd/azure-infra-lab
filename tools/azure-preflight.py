import argparse
import json
import re
import subprocess
from uuid import UUID


def read_azure(subscription, *command):
    operation = " ".join(command[:2])
    try:
        result = subprocess.run(
            [
                "az", *command, "--subscription", subscription,
                "--output", "json", "--only-show-errors",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except FileNotFoundError:
        raise ValueError("Azure CLI is required on the controller") from None
    except subprocess.TimeoutExpired:
        raise ValueError(f"Azure CLI timed out during {operation}") from None
    except OSError:
        raise ValueError("cannot execute Azure CLI") from None
    if result.returncode != 0:
        raise ValueError(
            f"Azure CLI failed during {operation}. Check sign-in, subscription, and read permissions."
        )
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise ValueError(f"Azure CLI returned invalid JSON during {operation}") from None


def quota_remaining(usage, name, required):
    matches = [
        item for item in usage
        if isinstance(item, dict)
        and isinstance(item.get("name"), dict)
        and str(item["name"].get("value", "")).casefold() == name.casefold()
    ]
    if len(matches) != 1:
        raise ValueError(f"quota response must contain one entry for {name}")
    current = matches[0].get("currentValue")
    limit = matches[0].get("limit")
    if type(current) is not int or type(limit) is not int or current < 0 or limit < 0:
        raise ValueError(f"quota response has invalid counts for {name}")
    remaining = limit - current
    if remaining < required:
        raise ValueError(f"insufficient {name} quota; need {required} vCPUs with {remaining} remaining")
    return remaining


def check(args):
    account = read_azure(args.subscription, "account", "show")
    if not isinstance(account, dict) or str(account.get("id", "")).lower() != args.subscription:
        raise ValueError("Azure CLI returned a different subscription")
    if account.get("state") != "Enabled":
        raise ValueError("the subscription must be Enabled")

    providers = ["Microsoft.Compute", "Microsoft.Network"]
    if args.with_cpu_alert:
        providers.append("Microsoft.Insights")
    for namespace in providers:
        provider = read_azure(args.subscription, "provider", "show", "--namespace", namespace)
        if not isinstance(provider, dict) or provider.get("registrationState") != "Registered":
            raise ValueError(f"{namespace} must be registered in the selected subscription")

    skus = read_azure(
        args.subscription, "vm", "list-skus", "--location", args.location,
        "--size", args.vm_size, "--resource-type", "virtualMachines", "--all",
    )
    if not isinstance(skus, list):
        raise ValueError("SKU response must be a list")
    matches = [
        sku for sku in skus
        if isinstance(sku, dict)
        and str(sku.get("name", "")).casefold() == args.vm_size.casefold()
        and sku.get("resourceType") == "virtualMachines"
    ]
    if len(matches) != 1:
        raise ValueError("the VM size must be listed exactly once for the selected region")
    sku = matches[0]
    locations = sku.get("locations")
    if not isinstance(locations, list) or args.location not in [str(item).lower() for item in locations]:
        raise ValueError("the VM size is not listed in the selected region")
    restrictions = sku.get("restrictions", [])
    if restrictions is None:
        restrictions = []
    if not isinstance(restrictions, list):
        raise ValueError("SKU restrictions must be a list")
    for restriction in restrictions:
        if not isinstance(restriction, dict) or restriction.get("type") not in ("Location", "Zone"):
            raise ValueError("SKU response has an unrecognized restriction")
        if restriction["type"] == "Zone":
            continue
        info = restriction.get("restrictionInfo", {})
        if info is None:
            info = {}
        if not isinstance(info, dict):
            raise ValueError("SKU response has invalid restriction details")
        blocked = restriction.get("values") or info.get("locations") or []
        if (
            not isinstance(blocked, list) or not blocked
            or args.location in [str(item).lower() for item in blocked]
        ):
            raise ValueError("the VM size has a location restriction in this subscription")

    family = sku.get("family")
    capabilities = sku.get("capabilities")
    if not isinstance(family, str) or not family or not isinstance(capabilities, list):
        raise ValueError("SKU response is missing the VM family or capabilities")
    cpu_values = [
        item.get("value") for item in capabilities
        if isinstance(item, dict) and item.get("name") == "vCPUs"
    ]
    if len(cpu_values) != 1 or not re.fullmatch(r"[1-9][0-9]*", str(cpu_values[0])):
        raise ValueError("SKU response must contain a positive vCPU count")
    required = int(cpu_values[0])
    usage = read_azure(args.subscription, "vm", "list-usage", "--location", args.location)
    if not isinstance(usage, list):
        raise ValueError("quota response must be a list")
    return {
        "location": args.location,
        "vm_size": sku["name"],
        "required_vcpus": required,
        "regional_vcpus_remaining": quota_remaining(usage, "cores", required),
        "family_vcpus_remaining": quota_remaining(usage, family, required),
        "status": "ok",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check Azure subscription, SKU restrictions, and vCPU quotas for one lab VM."
    )
    parser.add_argument("--subscription", required=True, help="Azure subscription UUID")
    parser.add_argument("--location", required=True, help="Azure region name, for example germanywestcentral")
    parser.add_argument("--vm-size", default="Standard_B2ls_v2")
    parser.add_argument(
        "--with-cpu-alert", action="store_true",
        help="Also require Microsoft.Insights registration",
    )
    args = parser.parse_args(argv)
    try:
        args.subscription = str(UUID(args.subscription))
    except ValueError:
        parser.error("--subscription must be a subscription UUID")
    if not re.fullmatch(r"[a-z][a-z0-9]+", args.location):
        parser.error("--location must be a canonical Azure region name")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.vm_size):
        parser.error("--vm-size must be an Azure VM size name")
    try:
        report = check(args)
    except ValueError as error:
        parser.exit(1, f"ERROR: {error}\n")
    for name, value in report.items():
        print(f"{name}={value}")


if __name__ == "__main__":
    main()
