mock_provider "azurerm" {
  source = "./tests/mocks"
}

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

  assert {
    condition = (
      length(azurerm_linux_virtual_machine.lab.boot_diagnostics) == 1 &&
      one(azurerm_linux_virtual_machine.lab.boot_diagnostics).storage_account_uri == null
    )
    error_message = "The VM must enable boot diagnostics with Azure-managed storage."
  }
}

run "verify_network_connections" {
  command = apply

  assert {
    condition = (
      azurerm_subnet_network_security_group_association.lab.subnet_id == azurerm_subnet.lab.id &&
      azurerm_subnet_network_security_group_association.lab.network_security_group_id == azurerm_network_security_group.lab.id
    )
    error_message = "The subnet must use the lab network security group."
  }

  assert {
    condition = (
      one(azurerm_network_interface.lab.ip_configuration).subnet_id == azurerm_subnet.lab.id &&
      one(azurerm_network_interface.lab.ip_configuration).public_ip_address_id == azurerm_public_ip.lab.id &&
      one(azurerm_linux_virtual_machine.lab.network_interface_ids) == azurerm_network_interface.lab.id
    )
    error_message = "The VM must use the lab NIC, secured subnet, and public IP."
  }

  assert {
    condition = (
      !azurerm_subnet.lab.default_outbound_access_enabled &&
      azurerm_public_ip.lab.sku == "Standard" &&
      azurerm_public_ip.lab.allocation_method == "Static"
    )
    error_message = "The lab must use its explicit public IP for outbound connectivity."
  }
}

run "reject_wide_ssh_access" {
  command = plan

  variables {
    ssh_source_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.ssh_source_cidr]
}

run "reject_subnet_ssh_access" {
  command = plan

  variables {
    ssh_source_cidr = "203.0.113.0/24"
  }

  expect_failures = [var.ssh_source_cidr]
}

run "reject_ipv6_ssh_source" {
  command = plan

  variables {
    ssh_source_cidr = "2001:db8::1/128"
  }

  expect_failures = [var.ssh_source_cidr]
}

run "reject_malformed_ssh_source" {
  command = plan

  variables {
    ssh_source_cidr = "invalid/32"
  }

  expect_failures = [var.ssh_source_cidr]
}

run "reject_blank_ssh_key" {
  command = plan

  variables {
    ssh_public_key = ""
  }

  expect_failures = [var.ssh_public_key]
}

run "reject_blank_location" {
  command = plan

  variables {
    location = " "
  }

  expect_failures = [var.location]
}
