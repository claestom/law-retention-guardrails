# Runbook deployment - Terraform

Deploys the table-retention Automation runbook: an Automation Account (system-assigned managed identity), the runbook, a weekly schedule, and a **Log Analytics Contributor** role assignment. Terraform embeds the runbook script directly from `../runbooks/Invoke-LawTableRetention.ps1`, so no content URL is needed.

## 1. Create `terraform.tfvars`

```powershell
cp terraform.tfvars.example terraform.tfvars   # then edit
```

| Variable | What it sets | Default |
|---|---|---|
| `subscription_id` | subscription to deploy into | **required** |
| `automation_resource_group_name` | RG that hosts the Automation Account | **required** |
| `target_resource_group_name` | RG holding the workspaces (also the default RBAC + runbook scope) | **required** |
| `schedule_start_time` | first schedule run (RFC3339, must be future) | **required** |
| `analytics_retention_in_days` | analytics retention written to tables | `-1` (inherit workspace) |
| `total_retention_in_days` | total (analytics + archive) retention | `730` |
| `workspace_name_filter` | limit to a single workspace | `''` (all in scope) |
| `scope_mode` | which workspaces the runbook enumerates: `ResourceGroup` \| `Subscription` \| `ManagementGroup` | `ResourceGroup` |
| `scope_subscription_id` | target sub for `Subscription` scope | `''` (identity's home sub) |
| `scope_management_group` | MG the runbook enumerates for `ManagementGroup` scope | `''` |
| `role_assignment_scope` | where the identity gets Log Analytics Contributor: `resource_group` \| `subscription` \| `management_group` | `resource_group` |
| `management_group_name` | MG for the role assignment when `role_assignment_scope = management_group` | `''` |
| `automation_account_name` | Automation Account to create | `aa-law-retention` |
| `runbook_name` / `schedule_name` | resource names | defaults |

## 2. Deploy

The Automation Account's resource group must already exist (Terraform references it via a data source). Create it first if needed:
```powershell
az group create -n <automation-rg> -l westeurope
```

```powershell
terraform init
terraform apply
```

## RBAC scope (subscription / management group)

Set `role_assignment_scope = "resource_group" | "subscription" | "management_group"` (add `management_group_name` for the last). A single `terraform apply` handles it - no second step.

Granting the role at subscription/management-group scope requires you to have **Owner** or **User Access Administrator** there.

---

See the [main README](../../README.md) for the retention model, runbook scope behavior, and changing settings later without a redeploy.
