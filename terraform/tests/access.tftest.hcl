mock_provider "azurerm" {}

variables {
  location        = "germanywestcentral"
  ssh_source_cidr = "203.0.113.10/32"
  ssh_public_key  = file("tests/fixtures/lab.pub")
}

run "restrict_vm_access" {
  command = plan

  assert {
    condition = alltrue([
      for rule in azurerm_network_security_group.lab.security_rule :
      rule.access != "Allow" || (
        rule.direction == "Inbound" && rule.priority == 100 &&
        rule.source_address_prefix == var.ssh_source_cidr &&
        rule.protocol == "Tcp" &&
        rule.destination_port_range == "22"
      )
      ]) && length([
      for rule in azurerm_network_security_group.lab.security_rule : rule
      if rule.access == "Allow"
    ]) == 1
    error_message = "The only allow rule must be SSH from the configured IPv4 address."
  }

  assert {
    condition = anytrue([
      for rule in azurerm_network_security_group.lab.security_rule :
      rule.direction == "Inbound" && rule.access == "Deny" &&
      rule.priority == 200 && rule.protocol == "*" &&
      rule.source_address_prefix == "*" && rule.destination_address_prefix == "*" &&
      rule.source_port_range == "*" && rule.destination_port_range == "*"
    ])
    error_message = "The network security group must deny other inbound traffic."
  }

  assert {
    condition = (
      azurerm_linux_virtual_machine.lab.disable_password_authentication &&
      azurerm_linux_virtual_machine.lab.secure_boot_enabled &&
      azurerm_linux_virtual_machine.lab.vtpm_enabled &&
      one(azurerm_linux_virtual_machine.lab.admin_ssh_key).public_key == trimspace(var.ssh_public_key)
    )
    error_message = "The VM must use key authentication with Secure Boot and vTPM enabled."
  }
}

run "reject_wide_ssh_access" {
  command = plan

  variables {
    ssh_source_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.ssh_source_cidr]
}
