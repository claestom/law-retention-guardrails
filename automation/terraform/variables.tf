variable "subscription_id" {
  type        = string
  description = "Azure subscription id to deploy into."
}

variable "automation_resource_group_name" {
  type        = string
  description = "Existing resource group that will host the Automation Account."
}

variable "target_resource_group_name" {
  type        = string
  description = "Resource group containing the Log Analytics workspaces to configure."
}

variable "automation_account_name" {
  type        = string
  default     = "aa-law-retention"
  description = "Name of the Automation Account to create."
}

variable "runbook_name" {
  type        = string
  default     = "Invoke-LawTableRetention"
  description = "Runbook name."
}

variable "schedule_name" {
  type        = string
  default     = "weekly-law-retention"
  description = "Schedule name."
}

variable "schedule_start_time" {
  type        = string
  description = "Schedule start time (RFC3339, must be >5 minutes in the future). Example: 2026-07-22T03:00:00Z"
}

variable "time_zone" {
  type        = string
  default     = "UTC"
  description = "Schedule time zone."
}

variable "analytics_retention_in_days" {
  type        = number
  default     = -1
  description = "Analytics (interactive) retention in days. -1 = same as workspace."
}

variable "total_retention_in_days" {
  type        = number
  default     = 730
  description = "Total retention in days (analytics + long-term). -1 = same as workspace."
}

variable "workspace_name_filter" {
  type        = string
  default     = ""
  description = "Optional single workspace name to target. Empty = all workspaces in the RG."
}

variable "role_assignment_scope" {
  type        = string
  default     = "resource_group"
  description = "Scope for the Log Analytics Contributor role: resource_group | subscription | management_group."
  validation {
    condition     = contains(["resource_group", "subscription", "management_group"], var.role_assignment_scope)
    error_message = "role_assignment_scope must be resource_group, subscription, or management_group."
  }
}

variable "management_group_name" {
  type        = string
  default     = ""
  description = "Management group name/id — required only when role_assignment_scope = management_group."
}
