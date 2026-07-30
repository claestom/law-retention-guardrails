terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# Resource group that will host the Automation Account (must already exist).
data "azurerm_resource_group" "automation" {
  name = var.automation_resource_group_name
}

# Resource group containing the Log Analytics workspaces to configure.
data "azurerm_resource_group" "target" {
  name = var.target_resource_group_name
}

# Automation Account names must be unique per subscription (across resource
# groups), so append a deterministic suffix derived from the resource group.
# Same RG => same name (idempotent); different RG => no collision.
locals {
  automation_account_name = "${var.automation_account_name}-${substr(sha1(data.azurerm_resource_group.automation.id), 0, 8)}"
}

resource "azurerm_automation_account" "this" {
  name                = local.automation_account_name
  location            = data.azurerm_resource_group.automation.location
  resource_group_name = data.azurerm_resource_group.automation.name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }
}

# ---- Configuration variables (editable in the portal after deploy) ----------
resource "azurerm_automation_variable_string" "resource_group" {
  name                    = "law-retention-resource-group"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.target_resource_group_name
}

resource "azurerm_automation_variable_string" "workspace" {
  count                   = var.workspace_name_filter != "" ? 1 : 0
  name                    = "law-retention-workspace"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.workspace_name_filter
}

resource "azurerm_automation_variable_string" "scope_mode" {
  name                    = "law-retention-scope-mode"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.scope_mode
}

resource "azurerm_automation_variable_string" "management_group" {
  count                   = var.scope_management_group != "" ? 1 : 0
  name                    = "law-retention-management-group"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.scope_management_group
}

resource "azurerm_automation_variable_string" "subscription" {
  count                   = var.scope_subscription_id != "" ? 1 : 0
  name                    = "law-retention-subscription"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.scope_subscription_id
}

resource "azurerm_automation_variable_int" "analytics_days" {
  name                    = "law-retention-analytics-days"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.analytics_retention_in_days
}

resource "azurerm_automation_variable_int" "total_days" {
  name                    = "law-retention-total-days"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.total_retention_in_days
}

resource "azurerm_automation_variable_int" "workspace_days" {
  name                    = "law-retention-workspace-days"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.workspace_retention_in_days
}

resource "azurerm_automation_variable_int" "throttle" {
  name                    = "law-retention-throttle"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.throttle_limit
}

# ---- Runbook (content inlined from the repo file) ---------------------------
resource "azurerm_automation_runbook" "this" {
  name                    = var.runbook_name
  location                = data.azurerm_resource_group.automation.location
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  log_verbose             = false
  log_progress            = false
  runbook_type            = "PowerShell72"
  description             = "Applies table-level retention across all Log Analytics workspaces in a resource group."

  content = file("${path.module}/../runbooks/Invoke-LawTableRetention.ps1")

  lifecycle {
    # Some azurerm versions read PowerShell72 back as "PowerShell", causing a
    # perpetual diff. The runbook is created as PowerShell 7.2 regardless.
    ignore_changes = [runbook_type]
  }
}

# ---- Weekly schedule --------------------------------------------------------
resource "azurerm_automation_schedule" "weekly" {
  name                    = var.schedule_name
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  frequency               = "Week"
  interval                = 1
  timezone                = var.time_zone
  start_time              = var.schedule_start_time != "" ? var.schedule_start_time : timeadd(timestamp(), "2h")
  week_days               = ["Sunday"]

  lifecycle {
    # start_time drifts into the past after creation and Azure normalizes the
    # timezone (UTC -> Etc/UTC); ignore both to avoid a perpetual diff/recreate.
    ignore_changes = [start_time, timezone]
  }
}

resource "azurerm_automation_job_schedule" "weekly" {
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  runbook_name            = azurerm_automation_runbook.this.name
  schedule_name           = azurerm_automation_schedule.weekly.name
}

# ---- RBAC: Log Analytics Contributor at the chosen scope ---------------------
locals {
  role_assignment_scope_id = (
    var.role_assignment_scope == "subscription" ? "/subscriptions/${var.subscription_id}" :
    var.role_assignment_scope == "management_group" ? "/providers/Microsoft.Management/managementGroups/${var.management_group_name}" :
    data.azurerm_resource_group.target.id
  )
}

resource "azurerm_role_assignment" "law_contributor" {
  scope                = local.role_assignment_scope_id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_automation_account.this.identity[0].principal_id
}
