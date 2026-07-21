<#
.SYNOPSIS
    Applies table-level retention (analytics + total) to every table in every
    Log Analytics workspace in a resource group.

.DESCRIPTION
    Loops over all Log Analytics workspaces in the given resource group and, for
    each table, sets:
      - Analytics retention (RetentionInDays)
      - Total retention     (TotalRetentionInDays)

    Use -1 for either value to mean "Same as workspace settings" (the table
    inherits the workspace default; long-term retention is removed).

    The script is idempotent: tables already matching the desired retention are
    skipped. Tables that don't support a retention change (e.g. some Basic/
    Auxiliary plan tables, or transient *_SRCH / *_RST tables) are caught and
    reported rather than failing the run.

    Supports -WhatIf to preview changes without applying them.

.PARAMETER ResourceGroupName
    Resource group containing the Log Analytics workspace(s).

.PARAMETER RetentionInDays
    Desired analytics (interactive) retention in days. Use -1 to inherit the
    workspace default. Default: -1.

.PARAMETER TotalRetentionInDays
    Desired total retention in days (analytics + long-term). Use -1 to inherit
    the workspace default (no long-term retention). Default: 730.

.PARAMETER WorkspaceName
    Optional. Restrict to a single workspace in the resource group.

.PARAMETER SubscriptionId
    Optional. Sets the Az context to this subscription before running. For
    Subscription scope this also selects which subscription's workspaces are
    enumerated; omit to use the current context subscription.

.EXAMPLE
    ./Set-LawTableRetention.ps1 -ResourceGroupName rg-azure-monitor-lab -WhatIf

.EXAMPLE
    ./Set-LawTableRetention.ps1 -ResourceGroupName rg-azure-monitor-lab -TotalRetentionInDays 730

.NOTES
    Requires the Az.OperationalInsights module and an authenticated Az session
    (Connect-AzAccount). The identity needs Log Analytics Contributor (or
    equivalent write access) on the workspaces.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('ResourceGroup', 'Subscription', 'ManagementGroup')]
    [string] $Scope = 'ResourceGroup',

    [string] $ResourceGroupName,

    [string] $ManagementGroupName,

    [int] $RetentionInDays = -1,

    [int] $TotalRetentionInDays = 730,

    [string] $WorkspaceName,

    [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'

# ---- Context ---------------------------------------------------------------
$ctx = Get-AzContext
if (-not $ctx) {
    throw "No Azure context found. Run Connect-AzAccount first."
}
if ($SubscriptionId) {
    if ($ctx.Subscription.Id -ne $SubscriptionId) {
        Write-Host "Setting subscription context to $SubscriptionId" -ForegroundColor Cyan
        Set-AzContext -Subscription $SubscriptionId | Out-Null
    }
}
Write-Host ("Subscription : {0} ({1})" -f (Get-AzContext).Subscription.Name, (Get-AzContext).Subscription.Id) -ForegroundColor Cyan
Write-Host ("Scope        : {0}" -f $Scope) -ForegroundColor Cyan
Write-Host ("Target retention : analytics={0}  total={1}  (-1 = same as workspace)" -f $RetentionInDays, $TotalRetentionInDays) -ForegroundColor Cyan
Write-Host ""

# ---- Helpers ---------------------------------------------------------------
# A table already matches the desired analytics retention when:
#   - desired is -1 and the table inherits the workspace default, OR
#   - the table's RetentionInDays equals the desired value.
function Test-RetentionMatch {
    param($current, $isDefault, $desired)
    if ($desired -eq -1) { return [bool]$isDefault }
    return ($current -eq $desired)
}

# Enumerate workspaces across subscriptions via Azure Resource Graph (needs Az.ResourceGraph).
function Get-GraphWorkspaces {
    param([string] $ManagementGroup, [string] $Subscription)
    $q = "resources | where type =~ 'microsoft.operationalinsights/workspaces' | project name, resourceGroup, subscriptionId"
    $out = @(); $skip = 0
    do {
        $p = @{ Query = $q; First = 1000; Skip = $skip }
        if ($ManagementGroup) { $p['ManagementGroup'] = $ManagementGroup }
        elseif ($Subscription) { $p['Subscription'] = @($Subscription) }
        $page = Search-AzGraph @p
        foreach ($r in $page) { $out += [pscustomobject]@{ SubscriptionId = $r.subscriptionId; ResourceGroupName = $r.resourceGroup; Name = $r.name } }
        $skip += $page.Count
    } while ($page.Count -eq 1000)
    return $out
}

# ---- Discover workspaces in scope ------------------------------------------
switch ($Scope) {
    'ResourceGroup' {
        if (-not $ResourceGroupName) { throw "Scope 'ResourceGroup' requires -ResourceGroupName." }
        $targets = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName | ForEach-Object {
            [pscustomobject]@{ SubscriptionId = (Get-AzContext).Subscription.Id; ResourceGroupName = $_.ResourceGroupName; Name = $_.Name }
        }
    }
    'Subscription' { $targets = Get-GraphWorkspaces -Subscription (Get-AzContext).Subscription.Id }
    'ManagementGroup' {
        if (-not $ManagementGroupName) { throw "Scope 'ManagementGroup' requires -ManagementGroupName." }
        $targets = Get-GraphWorkspaces -ManagementGroup $ManagementGroupName
    }
}
if ($WorkspaceName) { $targets = $targets | Where-Object { $_.Name -eq $WorkspaceName } }
if (-not $targets) { Write-Warning "No Log Analytics workspaces found for scope '$Scope'."; return }

$results = [System.Collections.Generic.List[object]]::new()
$currentSub = (Get-AzContext).Subscription.Id

foreach ($ws in $targets) {
    if ($ws.SubscriptionId -and $ws.SubscriptionId -ne $currentSub) {
        Set-AzContext -Subscription $ws.SubscriptionId | Out-Null
        $currentSub = $ws.SubscriptionId
    }
    Write-Host ("=== [{0}] {1}/{2} ===" -f $ws.SubscriptionId, $ws.ResourceGroupName, $ws.Name) -ForegroundColor Green
    $tables = Get-AzOperationalInsightsTable -ResourceGroupName $ws.ResourceGroupName -WorkspaceName $ws.Name

    foreach ($table in $tables) {
        $name = $table.Name

        $retMatch = Test-RetentionMatch -current $table.RetentionInDays -isDefault $table.RetentionInDaysAsDefault -desired $RetentionInDays
        $totMatch = Test-RetentionMatch -current $table.TotalRetentionInDays -isDefault $table.TotalRetentionInDaysAsDefault -desired $TotalRetentionInDays

        if ($retMatch -and $totMatch) {
            $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = $name; Status = 'Skipped (already compliant)' })
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($ws.Name)/$name", "Set retention analytics=$RetentionInDays total=$TotalRetentionInDays")) {
            try {
                $params = @{
                    ResourceGroupName    = $ws.ResourceGroupName
                    WorkspaceName        = $ws.Name
                    TableName            = $name
                    RetentionInDays      = $RetentionInDays
                    TotalRetentionInDays = $TotalRetentionInDays
                    ErrorAction          = 'Stop'
                }
                Update-AzOperationalInsightsTable @params | Out-Null
                Write-Host ("  [updated] {0}" -f $name) -ForegroundColor Yellow
                $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = $name; Status = 'Updated' })
            }
            catch {
                Write-Host ("  [skipped] {0} -> {1}" -f $name, $_.Exception.Message) -ForegroundColor DarkGray
                $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = $name; Status = "Failed: $($_.Exception.Message)" })
            }
        }
        else {
            $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = $name; Status = 'WhatIf (would update)' })
        }
    }
}

# ---- Summary ---------------------------------------------------------------
Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Cyan
$results | Group-Object Status | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("  {0,-45} {1}" -f $_.Name, $_.Count)
}
Write-Host ("  {0,-45} {1}" -f 'TOTAL tables processed', $results.Count)

# Emit the detailed results to the pipeline for further processing/export.
$results
