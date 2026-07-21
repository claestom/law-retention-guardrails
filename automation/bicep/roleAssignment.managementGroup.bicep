// Grants Log Analytics Contributor to the Automation Account managed identity at
// MANAGEMENT GROUP scope. Deploy after the main template (which outputs the principal id):
//   az deployment mg create -m <mgId> -l <location> -f roleAssignment.managementGroup.bicep `
//     -p principalId=<managedIdentityPrincipalId>

targetScope = 'managementGroup'

@description('Principal (object) id of the Automation Account managed identity.')
param principalId string

@description('Role definition id to assign (default: Log Analytics Contributor).')
param roleDefinitionId string = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, principalId, roleDefinitionId)
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
