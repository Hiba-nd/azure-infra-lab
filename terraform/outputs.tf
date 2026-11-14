output "public_ip" {
  description = "Public IPv4 address for the lab VM."
  value       = azurerm_public_ip.lab.ip_address
}

output "admin_username" {
  description = "SSH username for the Ansible inventory."
  value       = azurerm_linux_virtual_machine.lab.admin_username
}
