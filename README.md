# Log Analytics Retention Guardrails

Govern **Log Analytics data retention** - at the **workspace** level and per **table** - entirely with **Azure Policy** using the **DeployIfNotExists** effect. The policies both *audit* drift and *remediate* it: new and updated resources are configured automatically, and **remediation tasks** bring existing workspaces and tables into compliance. No Automation Account, runbook, or extra compute required.

> ⚠️ **Configure `deploy.ps1` first - it ships with the author's lab values.** The default **subscription id** inside `deploy.ps1` points at a demo environment - **replace it (or pass `-SubscriptionId <your-sub>`) before deploying**, or the command will target the wrong subscription.

## How it works

Two custom policy definitions, grouped into one initiative:

| Definition | Target | What it sets |
|---|---|---|
| `configure-law-workspace-retention` | `Microsoft.OperationalInsights/workspaces` | workspace default analytics retention |
| `configure-law-table-retention` | `Microsoft.OperationalInsights/workspaces/tables` | per-table analytics **and** total retention |

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
| **Analytics retention** | how long data stays "hot" and interactively queryable | `4`–`730` days, or `-1` |
| **Total retention** | analytics **+** long-term (archive) storage; must be ≥ analytics | `4`–`730`, or `1095, 1460, 1826, 2191, 2556, 2922, 3288, 3653, 4018, 4383` days, or `-1` |

Keep **analytics retention low** (e.g. 30 days) to control cost, and use **total retention** for cheaper long-term storage. The **workspace** retention is the default that tables inherit until a table-level value is set.

**What `-1` means.** For a table, `-1` = **"Same as workspace settings"** - the table doesn't pin its own value but **inherits the workspace default** (and, for total retention, keeps no long-term storage beyond that default). It's the same *Same as workspace settings* option you see in the portal's *Manage table* dropdown.

> ℹ️ **The DeployIfNotExists policies don't use `-1`.** They write **concrete** day counts, so `-1` (inherit) isn't a valid target for the policy - give it real numbers (e.g. analytics `30`, total `730`). `-1` is still useful with the optional manual [script](#optional-configure-a-workspace-once-manually) below, where it explicitly resets a table back to *inherit the workspace default*.

> ⚠️ **Basic / Auxiliary Logs tables always report non-compliant.** These plans have a fixed analytics retention (30 days) that can't be changed, so they can never match a different target analytics value. This is expected - treat those results as noise, or exclude those tables via a policy exemption.

## Deploy (script - does everything)

```powershell
./deploy.ps1 -SubscriptionId <sub-id>
```

This one command:

1. Creates/updates the two **policy definitions** and the **initiative**.
2. Creates the **assignment** with a **system-assigned managed identity** (DeployIfNotExists requires an identity + location).
3. Grants that identity **Log Analytics Contributor** at the scope (with retry for AAD propagation).
4. Starts a **remediation task** per member definition, to fix existing workspaces and tables.

Tune the target values with parameters (defaults shown):

```powershell
./deploy.ps1 -SubscriptionId <sub-id> `
  -WorkspaceRetentionInDays 30 `
  -TableRetentionInDays 30 `
  -TableTotalRetentionInDays 730
```

Other switches:

| Parameter | Purpose |
|---|---|
| `-ManagementGroupId <mgId>` | deploy + assign at management-group scope instead of a subscription |
| `-Location <region>` | region for the assignment's managed identity (default `westeurope`) |
| `-AssignmentName <name>` | assignment name (default `law-data-retention`) |
| `-SkipAssignment` | only (re)create the definitions and initiative; assign and remediate yourself later |

Track remediation in the portal under **Policy → Remediation**, or:

```powershell
az policy remediation list -o table
```

## Deploy (portal - manual)

1. **Policy → Definitions → + Policy definition** and paste each file's contents into the **POLICY RULE** box:
   - `policyDefinitions/configure-law-workspace-retention/azurepolicy.portal.json`
   - `policyDefinitions/configure-law-table-retention/azurepolicy.portal.json`
2. (Optional) Create an **initiative** from `policySetDefinitions/configure-law-data-retention/azurepolicy.json` referencing the two definitions.
3. **Assign** the definitions/initiative. On the assignment:
   - set the **effect** to `DeployIfNotExists` and the retention values,
   - enable a **system-assigned managed identity** and a **location**,
   - grant it **Log Analytics Contributor** at the scope (the portal offers to do this).
4. On the assignment's **Remediation** tab, **create a remediation task** for each policy to fix existing resources.

## Optional: configure a workspace once, manually

`scripts/Set-LawTableRetention.ps1` sets table retention imperatively for a resource group / subscription / management group (with `-WhatIf` preview). It's handy for a quick one-off pass or a smoke test, but it is **not required** - the DeployIfNotExists policies and remediation tasks above handle both new and existing resources.

```powershell
# preview (no changes)
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg> -WhatIf
# apply
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg> -RetentionInDays 30 -TotalRetentionInDays 730
# reset tables back to "Same as workspace settings" (inherit the workspace default)
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg> -RetentionInDays -1 -TotalRetentionInDays -1
```

Unlike the policy, this script accepts `-1` for either value to mean **"Same as workspace settings"** - use it to hand a table's retention back to the workspace default.

## Resources

- [Manage data retention in a Log Analytics workspace](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure)
- [Remediate non-compliant resources with Azure Policy](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources)
- [Azure Policy DeployIfNotExists effect](https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists)
