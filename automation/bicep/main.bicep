// -----------------------------------------------------------------------------
// Deploys an Azure Automation Account (system-assigned identity) with a runbook,
// config variables, a weekly schedule, and the Log Analytics Contributor role
// assignment needed to set table retention.
//
// Deploy into the resource group that should host the Automation Account:
//   az deployment group create -g rg-automation -f main.bicep -p main.bicepparam
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Base name for the Automation Account. A deterministic suffix derived from the resource group is appended, because Automation Account names must be unique per subscription (across resource groups).')
param automationAccountName string = 'aa-law-retention'

@description('Location for the Automation Account.')
param location string = resourceGroup().location

@description('Resource group that contains the Log Analytics workspaces to configure.')
param targetResourceGroupName string = resourceGroup().name

@description('Runbook scope: which workspaces it configures. ResourceGroup uses targetResourceGroupName; Subscription = all workspaces in the current subscription; ManagementGroup = all workspaces under managementGroupName.')
@allowed([
  'ResourceGroup'
  'Subscription'
  'ManagementGroup'
])
param scopeMode string = 'ResourceGroup'

@description('Management group id/name (only used when scopeMode = ManagementGroup).')
param managementGroupName string = ''

@description('Optional subscription id to target when scopeMode = Subscription. Empty = the Automation Account\'s own subscription (the managed identity\'s home sub).')
param subscriptionId string = ''

@description('Analytics (interactive) retention in days. -1 = same as workspace.')
param analyticsRetentionInDays int = -1

@description('Total retention in days (analytics + long-term). -1 = same as workspace.')
param totalRetentionInDays int = 730

@description('Workspace-level default retention in days. 0 or -1 = leave the workspace default unchanged; otherwise 30-730.')
param workspaceRetentionInDays int = -1

@description('Parallel table updates per workspace in the runbook. Default 10.')
param throttleLimit int = 10

@description('Optional single workspace name to target. Empty = all workspaces in the RG.')
param workspaceNameFilter string = ''

@description('Runbook name.')
param runbookName string = 'Invoke-LawTableRetention'

@description('Optional URI to the runbook .ps1 content (raw Git/SAS blob URL). Leave empty to create an empty runbook and upload content after deployment via az/PowerShell.')
param runbookContentUri string = ''

@description('Schedule name.')
param scheduleName string = 'weekly-law-retention'

@description('Schedule start time (ISO 8601, must be in the future). Defaults to ~2 hours from deploy time.')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT2H')

@description('Schedule time zone.')
param timeZone string = 'UTC'

@description('Log Analytics Contributor role definition id.')
param logAnalyticsContributorRoleId string = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'

@description('Create the Log Analytics Contributor role assignment on the target resource group. Set false to grant at subscription or management group scope instead, using roleAssignment.subscription.bicep / roleAssignment.managementGroup.bicep.')
param createRgRoleAssignment bool = true

// Automation Account names must be unique per subscription (across resource
// groups), so append a deterministic suffix derived from the resource group.
// Same RG => same name (idempotent re-deploys); different RG => no collision.
var automationAccountFullName = '${automationAccountName}-${uniqueString(resourceGroup().id)}'

resource aa 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountFullName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: aa
  name: runbookName
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logProgress: false
    logVerbose: false
    publishContentLink: empty(runbookContentUri) ? null : {
      uri: runbookContentUri
    }
  }
}

resource vRg 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-resource-group'
  properties: {
    isEncrypted: false
    value: '"${targetResourceGroupName}"'
  }
}

resource vScopeMode 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-scope-mode'
  properties: {
    isEncrypted: false
    value: '"${scopeMode}"'
  }
}

resource vManagementGroup 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-management-group'
  properties: {
    isEncrypted: false
    value: '"${managementGroupName}"'
  }
}

resource vSubscription 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-subscription'
  properties: {
    isEncrypted: false
    value: '"${subscriptionId}"'
  }
}

resource vWorkspace 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-workspace'
  properties: {
    isEncrypted: false
    value: '"${workspaceNameFilter}"'
  }
}

resource vAnalytics 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-analytics-days'
  properties: {
    isEncrypted: false
    value: string(analyticsRetentionInDays)
  }
}

resource vTotal 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-total-days'
  properties: {
    isEncrypted: false
    value: string(totalRetentionInDays)
  }
}

resource vWorkspaceDays 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-workspace-days'
  properties: {
    isEncrypted: false
    value: string(workspaceRetentionInDays)
  }
}

resource vThrottle 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: aa
  name: 'law-retention-throttle'
  properties: {
    isEncrypted: false
    value: string(throttleLimit)
  }
}

// Schedule + job schedule are only created when runbook content is supplied,
// because a job schedule can only bind to a PUBLISHED runbook.
resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (!empty(runbookContentUri)) {
  parent: aa
  name: scheduleName
  properties: {
    frequency: 'Week'
    interval: 1
    startTime: scheduleStartTime
    timeZone: timeZone
    advancedSchedule: {
      weekDays: [
        'Sunday'
      ]
    }
  }
}

resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (!empty(runbookContentUri)) {
  parent: aa
  name: guid(aa.id, runbookName, scheduleName)
  properties: {
    runbook: {
      name: runbook.name
    }
    schedule: {
      name: schedule.name
    }
  }
}

// Grant the managed identity Log Analytics Contributor on the target RG (may differ from this RG).
// For subscription / management group scope, set createRgRoleAssignment = false and deploy
// roleAssignment.subscription.bicep or roleAssignment.managementGroup.bicep separately.
module roleAssignment 'roleAssignment.bicep' = if (createRgRoleAssignment) {
  name: 'law-retention-role'
  scope: resourceGroup(targetResourceGroupName)
  params: {
    principalId: aa.identity.principalId
    roleDefinitionId: logAnalyticsContributorRoleId
  }
}

output automationAccountName string = aa.name
output managedIdentityPrincipalId string = aa.identity.principalId
