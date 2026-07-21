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

resource "azurerm_automation_account" "this" {
  name                = var.automation_account_name
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
  name                    = "law-retention-workspace"
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  value                   = var.workspace_name_filter
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
}

# ---- Weekly schedule --------------------------------------------------------
resource "azurerm_automation_schedule" "weekly" {
  name                    = var.schedule_name
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  frequency               = "Week"
  interval                = 1
  timezone                = var.time_zone
  start_time              = var.schedule_start_time
  week_days               = ["Sunday"]
}

resource "azurerm_automation_job_schedule" "weekly" {
  resource_group_name     = data.azurerm_resource_group.automation.name
  automation_account_name = azurerm_automation_account.this.name
  runbook_name            = azurerm_automation_runbook.this.name
  schedule_name           = azurerm_automation_schedule.weekly.name
}

# ---- RBAC: Log Analytics Contributor on the target RG -----------------------
resource "azurerm_role_assignment" "law_contributor" {
  scope                = data.azurerm_resource_group.target.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_automation_account.this.identity[0].principal_id
}
