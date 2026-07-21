using 'main.bicep'

param automationAccountName = 'aa-law-retention'
param targetResourceGroupName = 'rg-azure-monitor-lab'
param analyticsRetentionInDays = -1
param totalRetentionInDays = 730
param workspaceNameFilter = ''

// Leave empty to create an EMPTY runbook, then upload content after deployment
// (see the az/PowerShell commands in the deploy notes). Set a raw Git/SAS blob URL
// only if the .ps1 is reachable at deploy time.
param runbookContentUri = ''
