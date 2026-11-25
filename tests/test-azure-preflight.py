import importlib.util
import io
import json
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "azure-preflight.py"
SPEC = importlib.util.spec_from_file_location("azure_preflight", SCRIPT)
PREFLIGHT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREFLIGHT)
SUBSCRIPTION = "00000000-0000-0000-0000-000000000000"


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.account = {"id": SUBSCRIPTION, "state": "Enabled"}
        self.providers = dict.fromkeys(
            ("Microsoft.Compute", "Microsoft.Network", "Microsoft.Insights"), "Registered"
        )
        self.skus = [{
            "name": "Standard_B2ls_v2",
            "resourceType": "virtualMachines",
            "locations": ["germanywestcentral"],
            "family": "standardBsv2Family",
            "capabilities": [
                {"name": "vCPUs", "value": "2"},
                {"name": "CpuArchitectureType", "value": "x64"},
                {"name": "HyperVGenerations", "value": "V1,V2"},
            ],
            "restrictions": [],
        }]
        self.usage = [
            {"name": {"value": "cores"}, "currentValue": 4, "limit": 10},
            {"name": {"value": "standardBsv2Family"}, "currentValue": 0, "limit": 4},
        ]
        self.arguments = ["--subscription", SUBSCRIPTION, "--location", "germanywestcentral"]

    def azure_response(self, command, **kwargs):
        self.assertEqual(command[0], "az")
        self.assertEqual(command[command.index("--subscription") + 1], SUBSCRIPTION)
        self.assertEqual(command[command.index("--output") + 1], "json")
        self.assertIn("--only-show-errors", command)
        self.assertFalse(kwargs.get("shell", False))
        self.assertEqual(kwargs["timeout"], 60)
        operation = command[1:3]
        if operation == ["account", "show"]:
            payload = self.account
        elif operation == ["provider", "show"]:
            namespace = command[command.index("--namespace") + 1]
            payload = {"registrationState": self.providers[namespace]}
        elif operation == ["vm", "list-skus"]:
            self.assertEqual(command[command.index("--location") + 1], "germanywestcentral")
            self.assertIn("--all", command)
            payload = self.skus
        elif operation == ["vm", "list-usage"]:
            payload = self.usage
        else:
            self.fail(f"Unexpected Azure operation: {operation}")
        return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")

    def run_check(self, extra=(), side_effect=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        status = 0
        with patch.object(PREFLIGHT.subprocess, "run", side_effect=side_effect or self.azure_response) as calls:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                try:
                    PREFLIGHT.main([*self.arguments, *extra])
                except SystemExit as error:
                    status = error.code
        return status, stdout.getvalue(), stderr.getvalue(), calls.call_args_list

    def assert_failure(self, message, **kwargs):
        status, stdout, stderr, _ = self.run_check(**kwargs)
        self.assertEqual(status, 1, stderr)
        self.assertEqual(stdout, "")
        self.assertIn(message, stderr)
        return stderr

    def test_success_uses_only_subscription_scoped_reads(self):
        status, stdout, stderr, calls = self.run_check()
        self.assertEqual(status, 0, stderr)
        self.assertEqual(stderr, "")
        self.assertEqual(len(calls), 5)
        self.assertIn("required_vcpus=2\n", stdout)
        self.assertIn("regional_vcpus_remaining=6\n", stdout)
        self.assertIn("family_vcpus_remaining=4\n", stdout)
        self.assertTrue(stdout.endswith("status=ok\n"))

    def test_help_needs_no_azure_cli(self):
        status, stdout, stderr, calls = self.run_check(extra=["--help"])
        self.assertEqual(status, 0)
        self.assertIn("usage:", stdout)
        self.assertEqual(stderr, "")
        self.assertEqual(calls, [])

    def test_invalid_arguments_never_call_azure(self):
        for arguments in (
            ["--subscription", "invalid", "--location", "germanywestcentral"],
            ["--subscription", SUBSCRIPTION, "--location", "Germany West Central"],
        ):
            with self.subTest(arguments=arguments):
                self.arguments = arguments
                status, stdout, _, calls = self.run_check()
                self.assertEqual(status, 2)
                self.assertEqual(stdout, "")
                self.assertEqual(calls, [])

    def test_missing_cli_is_reported(self):
        self.assert_failure("Azure CLI is required", side_effect=FileNotFoundError())

    def test_cli_error_keeps_raw_diagnostics_out_of_report(self):
        result = subprocess.CompletedProcess([], 1, "", "private diagnostic marker")
        stderr = self.assert_failure("sign-in", side_effect=lambda *args, **kwargs: result)
        self.assertNotIn("private diagnostic marker", stderr)

    def test_cli_timeout_is_reported(self):
        self.assert_failure("timed out", side_effect=subprocess.TimeoutExpired("az", 60))

    def test_invalid_json_is_reported(self):
        result = subprocess.CompletedProcess([], 0, "invalid JSON", "")
        self.assert_failure("invalid JSON", side_effect=lambda *args, **kwargs: result)

    def test_wrong_or_disabled_subscription_is_rejected(self):
        self.account["id"] = "11111111-1111-1111-1111-111111111111"
        self.assert_failure("different subscription")
        self.account.update(id=SUBSCRIPTION, state="Disabled")
        self.assert_failure("must be Enabled")

    def test_unregistered_provider_is_rejected(self):
        self.providers["Microsoft.Network"] = "NotRegistered"
        self.assert_failure("Microsoft.Network must be registered")

    def test_cpu_alert_requires_insights_registration(self):
        self.providers["Microsoft.Insights"] = "NotRegistered"
        self.assert_failure("Microsoft.Insights must be registered", extra=["--with-cpu-alert"])

    def test_partial_sku_name_match_is_rejected(self):
        self.skus[0]["name"] = "Standard_B2ls_v2_extra"
        self.assert_failure("listed exactly once")

    def test_location_restriction_blocks_deployment(self):
        self.skus[0]["restrictions"] = [{"type": "Location", "values": ["germanywestcentral"]}]
        self.assert_failure("location restriction")

    def test_restriction_details_and_other_regions_are_handled(self):
        self.skus[0]["restrictions"] = [{
            "type": "Location", "restrictionInfo": {"locations": ["germanywestcentral"]},
        }]
        self.assert_failure("location restriction")
        self.skus[0]["restrictions"][0]["restrictionInfo"]["locations"] = ["westus"]
        status, _, stderr, _ = self.run_check()
        self.assertEqual(status, 0, stderr)

    def test_malformed_responses_are_rejected(self):
        self.skus[0]["restrictions"] = {}
        self.assert_failure("restrictions must be a list")
        self.skus = {}
        self.assert_failure("SKU response must be a list")

    def test_zone_restriction_allows_the_non_zonal_vm(self):
        self.skus[0]["restrictions"] = [{"type": "Zone", "values": ["1"]}]
        status, _, stderr, _ = self.run_check()
        self.assertEqual(status, 0, stderr)

    def test_regional_and_family_quotas_are_both_enforced(self):
        for quota in self.usage:
            with self.subTest(quota=quota["name"]["value"]):
                quota["limit"] = quota["currentValue"] + 1
                self.assert_failure("insufficient")
                quota["limit"] = quota["currentValue"] + 2
        status, _, stderr, _ = self.run_check()
        self.assertEqual(status, 0, stderr)

    def test_missing_or_invalid_quota_is_rejected(self):
        self.usage.pop()
        self.assert_failure("one entry for standardBsv2Family")
        self.usage[0]["limit"] = "10"
        self.assert_failure("invalid counts")

    def test_missing_cpu_capability_is_rejected(self):
        self.skus[0]["capabilities"] = []
        self.assert_failure("positive vCPU count")

    def test_gen1_size_is_rejected(self):
        for generations in ("V1", "V20"):
            with self.subTest(generations=generations):
                self.skus[0]["capabilities"][2]["value"] = generations
                self.assert_failure("Generation 2")

    def test_arm_size_is_rejected_for_the_x64_image(self):
        self.skus[0]["capabilities"][1]["value"] = "Arm64"
        self.assert_failure("x64 support")

    def test_explicit_trusted_launch_support_is_checked(self):
        self.skus[0]["capabilities"].append({"name": "TrustedLaunchDisabled", "value": "True"})
        self.assert_failure("explicitly disables Trusted Launch")
        self.skus[0]["capabilities"][-1]["value"] = "False"
        status, _, stderr, _ = self.run_check()
        self.assertEqual(status, 0, stderr)

    def test_missing_security_capabilities_are_rejected(self):
        original = list(self.skus[0]["capabilities"])
        for name, message in (
            ("CpuArchitectureType", "x64 support"),
            ("HyperVGenerations", "Generation 2"),
        ):
            with self.subTest(name=name):
                self.skus[0]["capabilities"] = [item for item in original if item["name"] != name]
                self.assert_failure(message)

    def test_malformed_or_duplicate_security_capabilities_are_rejected(self):
        original = list(self.skus[0]["capabilities"])
        for value in (None, "unknown"):
            with self.subTest(value=value):
                self.skus[0]["capabilities"] = [
                    *original, {"name": "TrustedLaunchDisabled", "value": value},
                ]
                self.assert_failure("invalid TrustedLaunchDisabled")
        self.skus[0]["capabilities"] = [
            *original, {"name": "HyperVGenerations", "value": "V1"},
        ]
        self.assert_failure("duplicate HyperVGenerations")


if __name__ == "__main__":
    unittest.main()
