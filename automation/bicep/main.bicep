// -----------------------------------------------------------------------------
// Deploys an Azure Automation Account (system-assigned identity) with a runbook,
// config variables, a weekly schedule, and the Log Analytics Contributor role
// assignment needed to set table retention.
//
// Deploy into the resource group that should host the Automation Account:
//   az deployment group create -g rg-automation -f main.bicep -p main.bicepparam
// -----------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Name of the Automation Account to create.')
param automationAccountName string = 'aa-law-retention'

@description('Location for the Automation Account.')
param location string = resourceGroup().location

@description('Resource group that contains the Log Analytics workspaces to configure.')
param targetResourceGroupName string = resourceGroup().name

@description('Analytics (interactive) retention in days. -1 = same as workspace.')
param analyticsRetentionInDays int = -1

@description('Total retention in days (analytics + long-term). -1 = same as workspace.')
param totalRetentionInDays int = 730

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

resource aa 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
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
module roleAssignment 'roleAssignment.bicep' = {
  name: 'law-retention-role'
  scope: resourceGroup(targetResourceGroupName)
  params: {
    principalId: aa.identity.principalId
    roleDefinitionId: logAnalyticsContributorRoleId
  }
}

output automationAccountName string = aa.name
output managedIdentityPrincipalId string = aa.identity.principalId
