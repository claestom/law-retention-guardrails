using 'main.bicep'

param automationAccountName = 'aa-law-retention'

// ---- Retention the runbook applies to every table --------------------------
param analyticsRetentionInDays = -1
param totalRetentionInDays = 730
param workspaceNameFilter = ''

// ---- Scope: which workspaces the runbook configures ------------------------
// ResourceGroup (default) | Subscription | ManagementGroup
param scopeMode = 'Subscription'

// Provide ONLY when scopeMode = 'ResourceGroup': the resource group holding the
// Log Analytics workspaces to configure (also where the identity is granted the
// role). Ignored for Subscription / ManagementGroup scope.
param targetResourceGroupName = 'rg-azure-monitor-lab'

// Provide ONLY when scopeMode = 'Subscription' to target a DIFFERENT subscription
// than the Automation Account's own. Empty = the identity's home subscription.
param subscriptionId = ''

// Provide ONLY when scopeMode = 'ManagementGroup': the management group id/name.
param managementGroupName = ''

// Keep true ONLY for ResourceGroup scope. For Subscription / ManagementGroup
// scope, set false and grant the identity via roleAssignment.subscription.bicep /
// roleAssignment.managementGroup.bicep at that broader scope instead.
param createRgRoleAssignment = false

// ---- Runbook content -------------------------------------------------------
// Leave empty to create an EMPTY runbook, then upload content after deployment
// (see the az/PowerShell commands in the deploy notes). Set a raw Git/SAS blob URL
// only if the .ps1 is reachable at deploy time.
param runbookContentUri = ''
