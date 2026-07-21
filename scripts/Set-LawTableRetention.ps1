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
    Optional. Sets the Az context to this subscription before running.

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
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

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
Write-Host ("Resource group : {0}" -f $ResourceGroupName) -ForegroundColor Cyan
Write-Host ("Target retention : analytics={0}  total={1}  (-1 = same as workspace)" -f $RetentionInDays, $TotalRetentionInDays) -ForegroundColor Cyan
Write-Host ""

# ---- Discover workspaces ---------------------------------------------------
$workspaces = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName
if ($WorkspaceName) {
    $workspaces = $workspaces | Where-Object { $_.Name -eq $WorkspaceName }
}
if (-not $workspaces) {
    Write-Warning "No Log Analytics workspaces found in resource group '$ResourceGroupName'."
    return
}

# ---- Helpers ---------------------------------------------------------------
# A table already matches the desired analytics retention when:
#   - desired is -1 and the table inherits the workspace default, OR
#   - the table's RetentionInDays equals the desired value.
function Test-RetentionMatch {
    param($current, $isDefault, $desired)
    if ($desired -eq -1) { return [bool]$isDefault }
    return ($current -eq $desired)
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($ws in $workspaces) {
    Write-Host ("=== Workspace: {0} ===" -f $ws.Name) -ForegroundColor Green
    $tables = Get-AzOperationalInsightsTable -ResourceGroupName $ResourceGroupName -WorkspaceName $ws.Name

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
                    ResourceGroupName    = $ResourceGroupName
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
