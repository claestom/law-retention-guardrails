# Log Analytics Retention Guardrails

Govern **Log Analytics data retention** at the workspace and table level.

- **Workspace + table retention → Azure Policy** (audit/deny/deploy) — the initiative in `policyDefinitions/` + `policySetDefinitions/`.
- **Table retention at scale → PowerShell / Automation runbook** (avoids per-table policy noise).

## Pick your path

| I want to… | Use |
|---|---|
| Deploy the policies via script | `./deploy.ps1` |
| Deploy the policies via portal | paste each `azurepolicy.portal.json` into **Policy → Definitions → + Policy definition** |
| Set table retention once, now | `./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg>` |
| Set table retention on a schedule | deploy the runbook (`automation/`) with Bicep or Terraform |

## Deploy the policy initiative

```powershell
./deploy.ps1 -SubscriptionId <sub-id>
```

## Set table retention (one-off)

```powershell
# preview first
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg> -WhatIf
# apply (analytics inherits workspace, total = 730 days)
./scripts/Set-LawTableRetention.ps1 -ResourceGroupName <rg>
```

## Set table retention on a schedule (runbook)

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

## Change settings later (no redeploy)

Portal → your Automation Account → **Shared Resources → Variables**, edit and save:

| Variable | Meaning |
|---|---|
| `law-retention-resource-group` | RG with the workspaces |
| `law-retention-workspace` | single workspace, or empty = all |
| `law-retention-analytics-days` | `-1` = same as workspace |
| `law-retention-total-days` | e.g. `730` |

Changes apply on the next run. Run now: Automation Account → **Runbooks** → `Invoke-LawTableRetention` → **Start** (pass `PREVIEWONLY = true` for a dry run).

## Retention values

- `-1` = **same as workspace** (inherit).
- Analytics: `4`–`730` days. Total: `4`–`730`, or `1095…4383`.

## Prerequisites

- Azure CLI + `Az.Accounts`, `Az.OperationalInsights` (also imported into the Automation Account for the runbook).
- **Log Analytics Contributor** on the target scope.

> Sample values in `deploy.ps1` / `*.bicepparam` / `*.tfvars.example` reference a lab subscription — change them to your own.
