mock_provider "azurerm" {
  source = "./tests/mocks"
}

variables {
  location        = "germanywestcentral"
  ssh_source_cidr = "203.0.113.10/32"
  ssh_public_key  = file("tests/fixtures/lab.pub")
}

run "alerts_disabled_by_default" {
  command = plan

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.cpu) == 0 &&
      length(azurerm_monitor_action_group.lab) == 0
    )
    error_message = "The default configuration must leave the optional alert resources out of the plan."
  }
}

run "cpu_alert_uses_vm_and_email" {
  command = apply

  variables {
    enable_cpu_alert    = true
    alert_email         = "alerts@example.test"
    cpu_alert_threshold = 75
  }

  assert {
    condition = (
      one(azurerm_monitor_metric_alert.cpu[0].scopes) == azurerm_linux_virtual_machine.lab.id &&
      azurerm_monitor_metric_alert.cpu[0].target_resource_type == "Microsoft.Compute/virtualMachines" &&
      azurerm_monitor_metric_alert.cpu[0].target_resource_location == var.location &&
      one(azurerm_monitor_metric_alert.cpu[0].action).action_group_id == azurerm_monitor_action_group.lab[0].id
    )
    error_message = "The CPU alert must monitor the lab VM and notify the configured action group."
  }

  assert {
    condition = (
      one(azurerm_monitor_metric_alert.cpu[0].criteria).metric_namespace == "Microsoft.Compute/virtualMachines" &&
      one(azurerm_monitor_metric_alert.cpu[0].criteria).metric_name == "Percentage CPU" &&
      one(azurerm_monitor_metric_alert.cpu[0].criteria).aggregation == "Average" &&
      one(azurerm_monitor_metric_alert.cpu[0].criteria).operator == "GreaterThan" &&
      one(azurerm_monitor_metric_alert.cpu[0].criteria).threshold == var.cpu_alert_threshold &&
      azurerm_monitor_metric_alert.cpu[0].frequency == "PT1M" &&
      azurerm_monitor_metric_alert.cpu[0].window_size == "PT5M" &&
      azurerm_monitor_metric_alert.cpu[0].severity == 2 &&
      azurerm_monitor_metric_alert.cpu[0].enabled &&
      azurerm_monitor_metric_alert.cpu[0].auto_mitigate
    )
    error_message = "The alert must evaluate average CPU over five minutes with the configured threshold."
  }

  assert {
    condition = (
      azurerm_monitor_action_group.lab[0].enabled &&
      one(azurerm_monitor_action_group.lab[0].email_receiver).email_address == var.alert_email &&
      one(azurerm_monitor_action_group.lab[0].email_receiver).use_common_alert_schema
    )
    error_message = "The action group must use the configured email address and common alert schema."
  }
}

run "remove_optional_alerts" {
  command = apply

  assert {
    condition = (
      length(azurerm_monitor_metric_alert.cpu) == 0 &&
      length(azurerm_monitor_action_group.lab) == 0
    )
    error_message = "Disabling the CPU alert must remove both optional monitoring resources."
  }
}

run "reject_missing_alert_email" {
  command = plan

  variables {
    enable_cpu_alert = true
  }

  expect_failures = [var.alert_email]
}

run "reject_invalid_alert_email" {
  command = plan

  variables {
    enable_cpu_alert = true
    alert_email      = "invalid-address"
  }

  expect_failures = [var.alert_email]
}

run "reject_negative_cpu_threshold" {
  command = plan

  variables {
    cpu_alert_threshold = -1
  }

  expect_failures = [var.cpu_alert_threshold]
}

run "reject_cpu_threshold_over_100" {
  command = plan

  variables {
    cpu_alert_threshold = 101
  }

  expect_failures = [var.cpu_alert_threshold]
}
