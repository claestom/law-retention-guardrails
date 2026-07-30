using 'main.bicep'

param automationAccountName = 'aa-law-retention'

// ---- Retention the runbook applies to every table --------------------------
param analyticsRetentionInDays = -1
param totalRetentionInDays = 730
// Workspace-level default retention: 0/-1 = leave unchanged, otherwise 30-730.
param workspaceRetentionInDays = -1
// Parallel table updates per workspace.
param throttleLimit = 10
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
// Bicep can't embed a local .ps1, so the content must come from a URL. The README
// passes this on the command line (-p runbookContentUri='<raw URL>'), which
// overrides the empty default below AND creates the weekly schedule. Leave empty
// only if you'd rather create an empty runbook and upload the script afterward
// (e.g. private repo / URL not reachable at deploy time).
param runbookContentUri = ''
