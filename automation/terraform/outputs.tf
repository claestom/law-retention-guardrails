output "automation_account_name" {
  value       = azurerm_automation_account.this.name
  description = "Name of the created Automation Account."
}

output "managed_identity_principal_id" {
  value       = azurerm_automation_account.this.identity[0].principal_id
  description = "Object id of the Automation Account system-assigned managed identity."
}

output "runbook_name" {
  value       = azurerm_automation_runbook.this.name
  description = "Name of the deployed runbook."
}
