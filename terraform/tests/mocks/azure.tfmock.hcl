mock_resource "azurerm_subnet" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/azure-infra-lab-rg/providers/Microsoft.Network/virtualNetworks/azure-infra-lab-vnet/subnets/lab"
  }
}

mock_resource "azurerm_network_security_group" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/azure-infra-lab-rg/providers/Microsoft.Network/networkSecurityGroups/azure-infra-lab-nsg"
  }
}

mock_resource "azurerm_public_ip" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/azure-infra-lab-rg/providers/Microsoft.Network/publicIPAddresses/azure-infra-lab-ip"
  }
}

mock_resource "azurerm_network_interface" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/azure-infra-lab-rg/providers/Microsoft.Network/networkInterfaces/azure-infra-lab-nic"
  }
}

mock_resource "azurerm_linux_virtual_machine" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/azure-infra-lab-rg/providers/Microsoft.Compute/virtualMachines/azure-infra-lab-vm"
  }
}

mock_resource "azurerm_monitor_action_group" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/azure-infra-lab-rg/providers/Microsoft.Insights/actionGroups/azure-infra-lab-alerts"
  }
}
