import json
import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "ansible" / "render-inventory.py"


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.outputs = {
            "public_ip": {"sensitive": False, "type": "string", "value": "192.0.2.10"},
            "admin_username": {"sensitive": False, "type": "string", "value": "labadmin"},
        }

    def render(self, stdin):
        return subprocess.run(
            [sys.executable, str(SCRIPT)], input=stdin, capture_output=True, text=True
        )

    def assert_rejected(self, stdin, message):
        result = self.render(stdin)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn(message, result.stderr)
        return result.stderr

    def test_renders_only_the_lab_host(self):
        self.outputs["extra"] = {"sensitive": True, "type": "string", "value": "test-only"}
        result = self.render(json.dumps(self.outputs))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        host = {"ansible_host": "192.0.2.10", "ansible_user": "labadmin"}
        groups = {"lab": {"hosts": {"lab-vm": host}}}
        self.assertEqual(json.loads(result.stdout), {"all": {"children": groups}})

    def test_rejects_empty_or_malformed_json(self):
        for stdin in ("", "{", "not json"):
            with self.subTest(stdin=stdin):
                self.assert_rejected(stdin, "expected JSON")

    def test_rejects_non_object_json(self):
        self.assert_rejected("[]", "expected a Terraform outputs object")

    def test_rejects_missing_outputs(self):
        for name in self.outputs:
            with self.subTest(name=name):
                outputs = {key: value for key, value in self.outputs.items() if key != name}
                self.assert_rejected(json.dumps(outputs), name)

    def test_rejects_non_string_output(self):
        self.outputs["public_ip"]["value"] = 3221225994
        self.assert_rejected(json.dumps(self.outputs), "public_ip")

    def test_rejects_sensitive_output_without_logging_it(self):
        self.outputs["admin_username"].update(sensitive=True, value="test-secret-value")
        stderr = self.assert_rejected(json.dumps(self.outputs), "admin_username")
        self.assertNotIn("test-secret-value", stderr)

    def test_rejects_invalid_ipv4(self):
        for address in ("192.0.2.256", "192.0.2.10/32", "::1", "192.0.2.10\n"):
            with self.subTest(address=address):
                self.outputs["public_ip"]["value"] = address
                self.assert_rejected(json.dumps(self.outputs), "public_ip must be an IPv4 address")

    def test_rejects_invalid_username(self):
        self.outputs["admin_username"]["value"] = "labadmin ansible_port=1"
        self.assert_rejected(json.dumps(self.outputs), "admin_username must be a Linux account name")


if __name__ == "__main__":
    unittest.main()
