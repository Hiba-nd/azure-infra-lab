resource "azurerm_monitor_action_group" "lab" {
  count = var.enable_cpu_alert ? 1 : 0

  name                = "${local.name}-alerts"
  resource_group_name = azurerm_resource_group.lab.name
  short_name          = "labalerts"
  enabled             = true
  tags                = local.tags

  email_receiver {
    name                    = "lab-owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "cpu" {
  count = var.enable_cpu_alert ? 1 : 0

  name                     = "${local.name}-cpu"
  resource_group_name      = azurerm_resource_group.lab.name
  scopes                   = [azurerm_linux_virtual_machine.lab.id]
  target_resource_type     = "Microsoft.Compute/virtualMachines"
  target_resource_location = azurerm_resource_group.lab.location
  description              = "Average VM CPU exceeds ${var.cpu_alert_threshold}% over five minutes."
  severity                 = 2
  frequency                = "PT1M"
  window_size              = "PT5M"
  enabled                  = true
  auto_mitigate            = true
  tags                     = local.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.cpu_alert_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.lab[0].id
  }
}
