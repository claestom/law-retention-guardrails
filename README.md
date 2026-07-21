# Log Analytics Retention Guardrails

Govern **Log Analytics data retention** — at the **workspace** level and per **table** — with Azure Policy for visibility and a script/runbook for configuration.

## Prerequisites

- Azure CLI + `Az.Accounts`, `Az.OperationalInsights` (also imported into the Automation Account for the runbook).
- **Log Analytics Contributor** on the target scope.

> Sample values in `deploy.ps1` / `*.bicepparam` / `*.tfvars.example` reference a lab subscription — change them to your own.

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

**`-1` = "Same as workspace settings"** — the table inherits the workspace's default retention instead of a fixed number. It's the default dropdown option in the portal. Use a number to pin a table; use `-1` to let it follow the workspace.

The **workspace** retention (set by the workspace policy) is the default that every `-1` table inherits.

> ⚠️ **Basic / Auxiliary Logs tables always report non-compliant.** These plans have a fixed analytics retention (30 days) that can't be changed, so they can never match the target analytics value. This is expected — treat those results as noise, or exclude those tables via a policy exemption.

## 1. Deploy the policies

```powershell
./deploy.ps1 -SubscriptionId <sub-id>
```
Creates the workspace + table retention policy definitions and the initiative. Assign it in **Audit** to report drift, or **DeployIfNotExists** to remediate the workspace setting.

## 2. Set table retention (separate script)

**Why a script instead of the policy?** A workspace exposes *every* built-in table as a resource — often 800–1500, most of them empty. A DeployIfNotExists policy would queue **one remediation deployment per table, per workspace** (slow, noisy, throttling-prone). The script loops tables directly, is **idempotent** (skips tables already correct), and lets you target exactly what you want. So: use the **policy to audit**, and this **script to configure**.

Run it once:
```powershell
# preview (no changes)
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg> -WhatIf
# apply — analytics inherits workspace (-1), total = 730 days
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg>
```

Or run it on a schedule via an Automation runbook:

**Bicep**
```powershell
az deployment group create -g <automation-rg> -f automation/bicep/main.bicep -p automation/bicep/main.bicepparam `
  -p runbookContentUri='https://raw.githubusercontent.com/claestom/law-retention-guardrails/main/automation/runbooks/Invoke-LawTableRetention.ps1'
```

**Terraform**
```powershell
cd automation/terraform; cp terraform.tfvars.example terraform.tfvars   # edit values
terraform init; terraform apply
```

Both create an Automation Account (managed identity), the runbook, a weekly schedule, and the **Log Analytics Contributor** role on the target RG.

### RBAC scope (where the identity gets Log Analytics Contributor)

Default is the **target resource group**. To cover more workspaces, widen the scope:

- **Terraform** — set `role_assignment_scope = "resource_group" | "subscription" | "management_group"` (plus `management_group_name` for the last). One `terraform apply` handles it.
- **Bicep** — an RG deployment can't assign at a higher scope, so for subscription/MG set `createRgRoleAssignment=false` on `main.bicep`, then deploy the matching template with the identity's principal id (from the main deploy output):
  ```powershell
  # subscription scope
  az deployment sub create -l <location> -f automation/bicep/roleAssignment.subscription.bicep -p principalId=<principalId>
  # management group scope
  az deployment mg create -m <mgId> -l <location> -f automation/bicep/roleAssignment.managementGroup.bicep -p principalId=<principalId>
  ```
  Broader scope also means the runbook can act on more workspaces — set `law-retention-resource-group` accordingly (and prefer least privilege).

## Change settings later (no redeploy)

Portal → Automation Account → **Shared Resources → Variables**, edit and save:

| Variable | Meaning |
|---|---|
| `law-retention-resource-group` | RG containing the workspaces |
| `law-retention-workspace` | one workspace name, or empty = all in the RG |
| `law-retention-analytics-days` | analytics retention (`-1` = inherit workspace) |
| `law-retention-total-days` | total retention (e.g. `730`) |

Changes apply on the next run. Run now: **Runbooks → `Invoke-LawTableRetention` → Start** (pass `PREVIEWONLY = true` for a dry run).
