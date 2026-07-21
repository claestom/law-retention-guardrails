// Role assignment scoped to the target resource group (deployed as a module so the
// scope can differ from the Automation Account's resource group).

targetScope = 'resourceGroup'

@description('Principal (object) id of the Automation Account managed identity.')
param principalId string

@description('Role definition id to assign (default: Log Analytics Contributor).')
param roleDefinitionId string = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
