# Log Analytics Retention Guardrails

Govern **Log Analytics data retention** - at the **workspace** level and per **table** - with Azure Policy for visibility and a script/runbook for configuration.

> ⚠️ **Configure these files first - they ship with the author's lab values.** The **subscription IDs** and **resource-group names** in `deploy.ps1`, `main.bicepparam` and `terraform.tfvars` point at a demo environment - **replace them with your own before deploying**, or the commands will target the wrong (or a non-existent) tenant. *(The runbook URL points at this repo and works as-is - only change it if you fork.)*

## Prerequisites

- Azure CLI + `Az.Accounts`, `Az.OperationalInsights` (also imported into the Automation Account for the runbook).
- **Log Analytics Contributor** on the target scope.

## Get the code

```bash
git clone https://github.com/claestom/law-retention-guardrails.git
cd law-retention-guardrails
```

Then edit the files in the **⚠️ Configure these files first** block below before running any command below.

<details>
<summary><b>Files that ship with lab values</b> (click to expand)</summary>

Replace these before deploying. Every other parameter (retention, scope, RBAC) is optional with a safe default - full lists are in the per-tool guides: **[Bicep](automation/bicep/README.md)** · **[Terraform](automation/terraform/README.md)**.

| File | Replace |
|---|---|
| `deploy.ps1` | `-SubscriptionId` / the guardrail sub id inside the script |
| `automation/bicep/main.bicepparam` | `targetResourceGroupName` |
| `automation/terraform/terraform.tfvars` (copy from `.example`) | `subscription_id`, `automation_resource_group_name`, `target_resource_group_name`, `schedule_start_time` |
| command args | every `<sub-id>`, `<rg>`, `<automation-rg>`, `<mgId>`, `<location>`, `<principalId>` |

</details>

## Pick your path

| I want to… | Use |
|---|---|
| Deploy the retention policies via script | `./deploy.ps1` |
| Deploy the retention policies via portal | paste each `azurepolicy.portal.json` into **Policy → Definitions → + Policy definition** |
| Set table retention once, now | `./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg>` |
| Set table retention on a schedule | deploy the runbook with Bicep or Terraform (below) |

## Retention model

Each table has **two** retention settings (the same ones you see in the portal's *Manage table* screen):

| Setting | What it controls | Allowed values |
|---|---|---|
| **Analytics retention** | how long data stays "hot" and interactively queryable | `4`–`730` days, or **`-1`** |
| **Total retention** | analytics **+** long-term (archive) storage; must be ≥ analytics | `4`–`730` / `1095…4383` days, or **`-1`** |

**`-1` = "Same as workspace settings"** - the table inherits the workspace's default retention instead of a fixed number. It's the default dropdown option in the portal. Use a number to pin a table; use `-1` to let it follow the workspace.

The **workspace** retention (set by the workspace policy) is the default that every `-1` table inherits.

> ⚠️ **Basic / Auxiliary Logs tables always report non-compliant.** These plans have a fixed analytics retention (30 days) that can't be changed, so they can never match the target analytics value. This is expected - treat those results as noise, or exclude those tables via a policy exemption.

## 1. Deploy the policies

```powershell
./deploy.ps1 -SubscriptionId <sub-id>
```
Creates the workspace + table retention policy definitions and the initiative. The initiative runs in **Audit** only - it reports workspaces and tables whose retention doesn't match, without changing anything.

<details>
<summary><b>Optional:</b> assign the initiative</summary>

The definitions/initiative only <i>describe</i> the rules - an **assignment** is what makes them evaluate against your resources. Assign the initiative in **Audit** so it reports workspaces and tables whose retention doesn't match, without changing anything.

```powershell
$sub = "<sub-id>"
$setId = az policy set-definition show --name configure-law-data-retention --query id -o tsv

'{"effect":{"value":"Audit"}}' | Set-Content assign-params.json -Encoding utf8
az policy assignment create --name law-data-retention `
  --display-name 'Audit Log Analytics data retention' `
  --policy-set-definition $setId --scope /subscriptions/$sub --params '@assign-params.json'
```

> This is **Audit only** - it just reports drift, so no managed identity or role assignment is needed. Table retention is configured by the Automation runbook in step 2, and workspace retention by the policy definition or the portal. Swap `/subscriptions/$sub` for `/providers/Microsoft.Management/managementGroups/<mg-id>` to assign at management-group scope.

</details>

## 2. Set table retention (separate script)

**Why a script instead of the policy?** A workspace exposes *every* built-in table as a resource - often 800-1500, most of them empty. A DeployIfNotExists policy would queue **one remediation deployment per table, per workspace** (slow, noisy, throttling-prone). The script loops tables directly, is **idempotent** (skips tables already correct), and lets you target exactly what you want. So: use the **policy to audit**, and this **script to configure**.

Run it once:

⚠️ Make sure to edit the values in the Set-LawTableRetention.ps1.

```powershell
# preview (no changes)
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg> -WhatIf
# apply - analytics inherits workspace (-1), total = 730 days
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg>
```

The default `-Scope` is `ResourceGroup`. To go wider, set `-Scope Subscription` or `-Scope ManagementGroup` (add `-WhatIf` to preview either):
```powershell
# every workspace in the current subscription (or pass -SubscriptionId <sub-id>)
./scripts/Set-LawTableRetention.ps1 -Scope Subscription

# every workspace under a management group
./scripts/Set-LawTableRetention.ps1 -Scope ManagementGroup -ManagementGroupName <mg-id>
```

Or run it on a schedule via an **Automation runbook** - each guide has the full parameter list.

Both tools expect the Automation Account's resource group to **already exist** (they reference it, they don't create it). Set the name once and reuse it - create the RG if needed:
```powershell
$automationRg = "rg-automation"
az group create -n $automationRg -l westeurope
```

**Bicep** ([full guide](automation/bicep/README.md))
```powershell
az deployment group create -g $automationRg -f automation/bicep/main.bicep -p automation/bicep/main.bicepparam `
  -p runbookContentUri='https://raw.githubusercontent.com/claestom/law-retention-guardrails/main/automation/runbooks/Invoke-LawTableRetention.ps1'
```

**Terraform** ([full guide](automation/terraform/README.md)) - set the same RG in `automation_resource_group_name` in your tfvars:
```powershell
cd automation/terraform; cp terraform.tfvars.example terraform.tfvars   # edit values
terraform init; terraform apply
```

Both deploy an Automation Account (system-assigned identity), the runbook, a weekly schedule, and a **Log Analytics Contributor** role assignment.

### Scope: two settings that must line up

| Setting | Controls | Where to set it |
|---|---|---|
| **Runbook scope** (`scopeMode` / `scope_mode`) | *what the runbook enumerates* | per-tool guide |
| **RBAC scope** | *what the identity is allowed to touch* | per-tool guide |

Runbook scope options:

| Scope | Runbook enumerates |
|---|---|
| `ResourceGroup` (default) | workspaces in the target resource group |
| `Subscription` | every workspace in one subscription (the identity's home sub, or a chosen one) |
| `ManagementGroup` | every workspace under a management group (all child subscriptions) |

> Widen **both** together, or writes fail where the identity lacks access. For `Subscription` / `ManagementGroup` the runbook enumerates with `Az.Resources` + `Az.OperationalInsights` (already in the Automation Account) - no extra module import needed.

## Change settings later (no redeploy)

Portal → Automation Account → **Shared Resources → Variables**, edit and save:

| Variable | Meaning |
|---|---|
| `law-retention-scope-mode` | `ResourceGroup` \| `Subscription` \| `ManagementGroup` |
| `law-retention-resource-group` | RG containing the workspaces (scope = ResourceGroup) |
| `law-retention-management-group` | management group id (scope = ManagementGroup) |
| `law-retention-subscription` | subscription id (scope = Subscription; empty = identity's home sub) |
| `law-retention-workspace` | one workspace name, or empty = all in scope |
| `law-retention-analytics-days` | analytics retention (`-1` = inherit workspace) |
| `law-retention-total-days` | total retention (e.g. `730`) |

Changes apply on the next run. Run now: **Runbooks → `Invoke-LawTableRetention` → Start** (pass `PREVIEWONLY = true` for a dry run).
