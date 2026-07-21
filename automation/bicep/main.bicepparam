using 'main.bicep'

param automationAccountName = 'aa-law-retention'
param targetResourceGroupName = 'rg-azure-monitor-lab'
param analyticsRetentionInDays = -1
param totalRetentionInDays = 730
param workspaceNameFilter = ''

// Scope of workspaces the runbook configures:
//   ResourceGroup (default) | Subscription | ManagementGroup
param scopeMode = 'ResourceGroup'
// Only used when scopeMode = 'ManagementGroup'
param managementGroupName = ''
// Only used when scopeMode = 'Subscription' to target a DIFFERENT subscription than
// the Automation Account's own. Empty = the identity's home subscription.
param subscriptionId = ''
// Set false for Subscription/ManagementGroup scope, then grant the identity
// via roleAssignment.subscription.bicep / roleAssignment.managementGroup.bicep
param createRgRoleAssignment = true

// Leave empty to create an EMPTY runbook, then upload content after deployment
// (see the az/PowerShell commands in the deploy notes). Set a raw Git/SAS blob URL
// only if the .ps1 is reachable at deploy time.
param runbookContentUri = ''
