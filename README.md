# Log Analytics Retention Guardrails

Govern **Log Analytics data retention** - at the **workspace** level and per **table** - entirely with **Azure Policy** using the **DeployIfNotExists** effect. The policies both *audit* drift and *remediate* it: new and updated resources are configured automatically, and **remediation tasks** bring existing workspaces and tables into compliance. No Automation Account, runbook, or extra compute required.

> ⚠️ **Configure `deploy.ps1` first - it ships with the author's lab values.** The default **subscription id** inside `deploy.ps1` points at a demo environment - **replace it (or pass `-SubscriptionId <your-sub>`) before deploying**, or the command will target the wrong subscription.

## Deploy with one click

<p align="center">
  <a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fclaestom%2Flaw-retention-guardrails%2Fmain%2Fazuredeploy.json"><img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure" /></a>
</p>

The button opens a **subscription-scoped** deployment of [`azuredeploy.json`](azuredeploy.json): pick the subscription and region, adjust the retention values, and deploy. It creates the three policy definitions, the initiative, the **assignment (with a managed identity)**, and the **Log Analytics Contributor** role assignment - so new and updated workspaces/tables are configured automatically.

<details>
<summary><b>Scope options &amp; permissions</b> (click to expand)</summary>

> **Scope it to a resource group:** leave **Assignment Resource Group** empty to assign at the whole subscription, or enter an **existing** resource group name to scope the assignment (and its managed identity + role) to just that RG. The policy *definitions* are always created at the subscription; only the assignment is narrowed.

> **Scoping to an individual resource (a resource id) is not supported by the button.** The one-click template can only assign at the **subscription** or a **resource group**. To target a single resource - e.g. one Log Analytics workspace - use the **deploy script**: `./deploy.ps1 -SubscriptionId <sub> -Scope <resourceId>` (see [Deploy (script)](#deploy-script---does-everything)).

> You need permission to create policy and **role** assignments at the subscription (e.g. **Owner**). To fix **existing** resources after deploying, create a remediation task under **Policy → Remediation** (or run `deploy.ps1`, which starts them for you).

</details>

Prefer scripts or the portal instead? Continue below.

## How it works

Three custom policy definitions, grouped into one initiative:

| Definition | Target | What it sets |
|---|---|---|
| `configure-law-workspace-retention` | `Microsoft.OperationalInsights/workspaces` | workspace default analytics retention |
| `configure-law-table-retention` | `Microsoft.OperationalInsights/workspaces/tables` | per-table analytics **and** total retention (excludes the App Insights tables) |
| `configure-appinsights-table-retention` | `Microsoft.OperationalInsights/workspaces/tables` | analytics **and** total retention for the 11 App Insights (`App*`) tables |

Both use **DeployIfNotExists**: when a resource's retention doesn't match the target, Policy deploys a small ARM update to correct it. Compliance is visible in **Policy → Compliance**, and existing resources are fixed by **remediation tasks** (created for you by `deploy.ps1`).

## Prerequisites

- Azure CLI with the `Az.Accounts` and `Az.OperationalInsights` modules available (the deploy script uses `az`).
- Rights to **create policy definitions/assignments and role assignments** at the target scope (e.g. **Owner**, or **Resource Policy Contributor** + **User Access Administrator**). DeployIfNotExists creates a managed identity that needs **Log Analytics Contributor** granted to it.

## Get the code

```bash
git clone https://github.com/claestom/law-retention-guardrails.git
cd law-retention-guardrails
```

## Retention model

Each table has **two** retention settings (the same ones you see in the portal's *Manage table* screen):

| Setting | What it controls | Allowed values |
|---|---|---|
| **Analytics retention** | how long data stays "hot" and interactively queryable | `4`–`730` days |
| **Total retention** | analytics **+** long-term (archive) storage; must be ≥ analytics | `4`–`730`, or `1095, 1460, 1826, 2191, 2556, 2922, 3288, 3653, 4018, 4383` days |

Keep **analytics retention low** (e.g. 30 days) to control cost, and use **total retention** for cheaper long-term storage. The **workspace** retention is the default that tables inherit until a table-level value is set.

> ⚠️ **Basic / Auxiliary Logs tables always report non-compliant.** These plans have a fixed analytics retention (30 days) that can't be changed, so they can never match a different target analytics value. This is expected - treat those results as noise, or exclude those tables via a policy exemption.

## Deploy (script - does everything)

```powershell
./deploy.ps1 -SubscriptionId <sub-id>
```

This one command:

1. Creates/updates the three **policy definitions** and the **initiative**.
2. Creates the **assignment** with a **system-assigned managed identity** (DeployIfNotExists requires an identity + location).
3. Grants that identity **Log Analytics Contributor** at the scope (with retry for AAD propagation).
4. Starts a **remediation task** per member definition, to fix existing workspaces and tables.

Tune the target values with parameters (defaults shown):

```powershell
./deploy.ps1 -SubscriptionId <sub-id> `
  -WorkspaceRetentionInDays 30 `
  -TableRetentionInDays 30 `
  -TableTotalRetentionInDays 730 `
  -AppInsightsRetentionInDays 90 `
  -AppInsightsTotalRetentionInDays 90
```

Other switches:

| Parameter | Purpose |
|---|---|
| `-ManagementGroupId <mgId>` | deploy + assign at management-group scope instead of a subscription |
| `-ResourceGroupName <rg>` | assign at a single **resource group** (within `-SubscriptionId`) instead of the whole subscription |
| `-Scope <resourceId>` | assign at an explicit scope - a resource group or an **individual resource** (e.g. one Log Analytics workspace). Overrides the above for the assignment, role grant and remediation |
| `-Location <region>` | region for the assignment's managed identity (default `westeurope`) |
| `-AssignmentName <name>` | assignment name (default `law-data-retention`) |
| `-AppInsightsRetentionInDays <n>` | analytics retention for the App Insights (`App*`) tables (default `90`) |
| `-AppInsightsTotalRetentionInDays <n>` | total retention for the App Insights (`App*`) tables (default `90`) |
| `-SkipAssignment` | only (re)create the definitions and initiative; assign and remediate yourself later |

The policy **definitions and initiative** are always created at the subscription (or management group); only the **assignment** (plus its managed-identity role grant and remediation) is narrowed to the resource group or resource. Examples:

```powershell
# Assign to a single resource group
./deploy.ps1 -SubscriptionId <sub> -ResourceGroupName rg-monitoring

# Assign to a single Log Analytics workspace
./deploy.ps1 -SubscriptionId <sub> `
  -Scope /subscriptions/<sub>/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-prod
```

Track remediation in the portal under **Policy → Remediation**, or:

```powershell
az policy remediation list -o table
```

## Deploy (portal - manual)

1. **Policy → Definitions → + Policy definition** and paste each file's contents into the **POLICY RULE** box:
   - `policyDefinitions/configure-law-workspace-retention/azurepolicy.portal.json`
   - `policyDefinitions/configure-law-table-retention/azurepolicy.portal.json`
   - `policyDefinitions/configure-appinsights-table-retention/azurepolicy.portal.json`
2. (Optional) Create an **initiative** from `policySetDefinitions/configure-law-data-retention/azurepolicy.json` referencing the three definitions.
3. **Assign** the definitions/initiative. On the assignment:
   - choose the **scope** - a management group, subscription, **resource group**, or an **individual resource** (e.g. one workspace),
   - set the **effect** to `DeployIfNotExists` and the retention values,
   - enable a **system-assigned managed identity** and a **location**,
   - grant it **Log Analytics Contributor** at the scope (the portal offers to do this).
4. On the assignment's **Remediation** tab, **create a remediation task** for each policy to fix existing resources.

## Sentinel & Application Insights (keep the free 90 days)

Enabling **Microsoft Sentinel** on a workspace, or using workspace-based **Application Insights**, gives you **90 days of interactive (analytics) retention for free**. A blanket 30-day analytics target would throw that away.

**Application Insights - handled automatically.** The initiative ships a dedicated third member (`configure-appinsights-table-retention`) that targets exactly the 11 workspace-based App Insights tables (`AppAvailabilityResults`, `AppBrowserTimings`, `AppDependencies`, `AppEvents`, `AppExceptions`, `AppMetrics`, `AppPageViews`, `AppPerformanceCounters`, `AppRequests`, `AppSystemEvents`, `AppTraces`). The general table policy **excludes those same tables**, so there's no overlap and no second assignment - one assignment governs everything. App Insights keeps its own values via `-AppInsightsRetentionInDays` / `-AppInsightsTotalRetentionInDays` (default **90 / 90**):

```powershell
# One assignment: workspace + general tables at 30, App Insights tables at 90
./deploy.ps1 -SubscriptionId <sub> `
  -WorkspaceRetentionInDays 30 -TableRetentionInDays 30 -TableTotalRetentionInDays 730 `
  -AppInsightsRetentionInDays 90 -AppInsightsTotalRetentionInDays 90
```

> The App Insights member matches on the exact table names (`in [...]`). If `field('name')` resolves to the full `workspace/table` name in your tenant, tell us and we'll switch it to a `like '*/App…'` form.

**Sentinel - split by scope.** Sentinel gives free 90-day retention at the **workspace** level, which the general table exclusions don't cover. Assuming Sentinel runs in a dedicated workspace/resource group, assign 90-day values there and **carve that scope out of the baseline** with `-NotScopes`:

> ⚠️ Keep any *extra* assignments **mutually exclusive**. Two DeployIfNotExists assignments that both match the same table will fight (each keeps re-remediating to its own value). Split by **scope** (`-NotScopes`), never let them overlap.

```powershell
$sentinelRg = "/subscriptions/<sub>/resourceGroups/rg-sentinel"

# Baseline everywhere except the Sentinel RG
./deploy.ps1 -SubscriptionId <sub> -AssignmentName law-retention-base -NotScopes $sentinelRg

# Sentinel RG at 90 days
./deploy.ps1 -SubscriptionId <sub> -AssignmentName law-retention-sentinel `
  -WorkspaceRetentionInDays 90 -TableRetentionInDays 90 -TableTotalRetentionInDays 730
```

> Each assignment gets its **own** managed identity and **its own** Log Analytics Contributor grant - `deploy.ps1` does that per run. Keep the **workspace** retention value identical across any two assignments that both manage the same workspace, or they'll conflict on that setting.

## Optional: configure a workspace once, manually

`scripts/Set-LawTableRetention.ps1` sets table retention imperatively for a resource group / subscription / management group (with `-WhatIf` preview). It's handy for a quick one-off pass or a smoke test, but it is **not required** - the DeployIfNotExists policies and remediation tasks above handle both new and existing resources.

```powershell
# preview (no changes)
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg> -WhatIf
# apply
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg> -RetentionInDays 30 -TotalRetentionInDays 730
```

## Resources

- [Manage data retention in a Log Analytics workspace](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure)
- [Remediate non-compliant resources with Azure Policy](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources)
- [Azure Policy DeployIfNotExists effect](https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists)
