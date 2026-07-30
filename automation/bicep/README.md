# Runbook deployment - Bicep

Deploys the table-retention Automation runbook: an Automation Account (system-assigned managed identity), the runbook, a weekly schedule, and a **Log Analytics Contributor** role assignment.

| File | Purpose |
|---|---|
| `main.bicep` | the deployment |
| `main.bicepparam` | **your values - edit this** |
| `roleAssignment.bicep` | RG-scoped role (used inline by `main.bicep`) |
| `roleAssignment.subscription.bicep` / `roleAssignment.managementGroup.bicep` | wider-scope role grants |

## 1. Edit `main.bicepparam`

| Parameter | What it sets | Default |
|---|---|---|
| `targetResourceGroupName` | RG holding the workspaces (also the default RBAC + runbook scope) | **required** |
| `runbookContentUri` | raw URL Bicep pulls the runbook from | `''` -> empty runbook; set the raw URL or upload after |
| `scheduleStartTime` | first schedule run (ISO 8601, must be future) | now + 2h |
| `analyticsRetentionInDays` | analytics retention written to tables | `-1` (inherit workspace) |
| `totalRetentionInDays` | total (analytics + archive) retention | `730` |
| `workspaceNameFilter` | limit to a single workspace | `''` (all in scope) |
| `scopeMode` | which workspaces the runbook enumerates: `ResourceGroup` \| `Subscription` \| `ManagementGroup` | `ResourceGroup` |
| `subscriptionId` | target sub for `Subscription` scope | `''` (identity's home sub) |
| `managementGroupName` | MG the runbook enumerates for `ManagementGroup` scope | `''` |
| `createRgRoleAssignment` | grant the identity Log Analytics Contributor on the target RG | `true` |
| `automationAccountName` | base name (a unique per-RG suffix is appended) | `aa-law-retention` |
| `runbookName` / `scheduleName` | resource names | defaults |

> Bicep can't embed a local file, so the runbook content comes from `runbookContentUri`. Leave it empty to create an empty runbook and upload the script afterward, or point it at the raw file URL:
> `https://raw.githubusercontent.com/claestom/law-retention-guardrails/main/automation/runbooks/Invoke-LawTableRetention.ps1`

## 2. Deploy

The Automation Account's resource group must already exist (Bicep references it). Set the name once and reuse it - create the RG if needed:
```powershell
$automationRg = "rg-automation"
az group create -n $automationRg -l westeurope
```

```powershell
az deployment group create -g $automationRg -f main.bicep -p main.bicepparam `
  -p runbookContentUri='https://raw.githubusercontent.com/claestom/law-retention-guardrails/main/automation/runbooks/Invoke-LawTableRetention.ps1'
```

## RBAC scope (subscription / management group)

`main.bicep` can only grant the role on its own resource group. For wider scope set `createRgRoleAssignment=false`, deploy, then grant at the higher scope using the identity's principal id (from the deploy output `managedIdentityPrincipalId`):

```powershell
# subscription
az deployment sub create -l <location> -f roleAssignment.subscription.bicep -p principalId=<principalId>
# management group
az deployment mg create -m <mgId> -l <location> -f roleAssignment.managementGroup.bicep -p principalId=<principalId>
```

Granting the role at subscription/management-group scope requires you to have **Owner** or **User Access Administrator** there.

---

See the [main README](../../README.md) for the retention model, runbook scope behavior, and changing settings later without a redeploy.
