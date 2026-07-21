<#
.SYNOPSIS
    Azure Automation runbook — applies table-level retention (analytics + total) to
    every table in every Log Analytics workspace in a resource group.

.DESCRIPTION
    Authenticates with the Automation Account's system-assigned managed identity and
    loops over all workspaces/tables in the target resource group, setting analytics
    and total retention. Idempotent (skips already-compliant tables) and resilient
    (non-updatable tables are logged and skipped).

    Configuration is read from Automation Variables, so it can be changed AFTER
    deployment without editing the runbook:
      - law-retention-resource-group  (string)
      - law-retention-workspace       (string, empty = all workspaces in the RG)
      - law-retention-analytics-days  (int, -1 = same as workspace)
      - law-retention-total-days      (int, e.g. 730; -1 = same as workspace)

    Any value passed as a runbook parameter (e.g. from a schedule) overrides the
    matching Automation Variable.

.NOTES
    Runbook type: PowerShell 7.2. Requires the Az.Accounts and Az.OperationalInsights
    modules imported into the Automation Account, and the managed identity granted
    'Log Analytics Contributor' on the target resource group.
#>
param(
    [string] $ResourceGroupName,
    [string] $WorkspaceName,
    [string] $RetentionInDays,
    [string] $TotalRetentionInDays,
    [string] $PreviewOnly    # 'true' to preview (no changes)
)

$ErrorActionPreference = 'Stop'

Write-Output 'Authenticating with the Automation managed identity...'
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null

# ---- Resolve config: runbook parameter overrides Automation Variable --------
function Resolve-Config {
    param([string] $ParamValue, [string] $VariableName, [switch] $Optional)
    if (-not [string]::IsNullOrWhiteSpace($ParamValue)) { return $ParamValue }
    try { return (Get-AutomationVariable -Name $VariableName) }
    catch {
        if ($Optional) { return $null }
        throw "Missing configuration: provide the '$VariableName' Automation Variable or pass the matching runbook parameter."
    }
}

$rg     = Resolve-Config -ParamValue $ResourceGroupName    -VariableName 'law-retention-resource-group'
$wsName = Resolve-Config -ParamValue $WorkspaceName        -VariableName 'law-retention-workspace' -Optional
$ret    = [int](Resolve-Config -ParamValue $RetentionInDays      -VariableName 'law-retention-analytics-days')
$total  = [int](Resolve-Config -ParamValue $TotalRetentionInDays -VariableName 'law-retention-total-days')
$whatIf = ($PreviewOnly -eq 'true')

Write-Output "Resource group  : $rg"
Write-Output ("Workspace filter: {0}" -f ([string]::IsNullOrWhiteSpace($wsName) ? '(all)' : $wsName))
Write-Output "Target retention: analytics=$ret total=$total  (-1 = same as workspace)  PreviewOnly=$whatIf"

function Test-RetentionMatch {
    param($current, $isDefault, $desired)
    if ($desired -eq -1) { return [bool] $isDefault }
    return ($current -eq $desired)
}

$workspaces = Get-AzOperationalInsightsWorkspace -ResourceGroupName $rg
if (-not [string]::IsNullOrWhiteSpace($wsName)) {
    $workspaces = $workspaces | Where-Object { $_.Name -eq $wsName }
}
if (-not $workspaces) { Write-Warning "No Log Analytics workspaces found in '$rg'."; return }

$updated = 0; $compliant = 0; $failed = 0
foreach ($ws in $workspaces) {
    Write-Output "=== Workspace: $($ws.Name) ==="
    $tables = Get-AzOperationalInsightsTable -ResourceGroupName $rg -WorkspaceName $ws.Name
    foreach ($t in $tables) {
        $retOk = Test-RetentionMatch -current $t.RetentionInDays      -isDefault $t.RetentionInDaysAsDefault      -desired $ret
        $totOk = Test-RetentionMatch -current $t.TotalRetentionInDays -isDefault $t.TotalRetentionInDaysAsDefault -desired $total
        if ($retOk -and $totOk) { $compliant++; continue }

        if ($whatIf) { Write-Output "  [preview] would update $($t.Name)"; continue }
        try {
            Update-AzOperationalInsightsTable -ResourceGroupName $rg -WorkspaceName $ws.Name `
                -TableName $t.Name -RetentionInDays $ret -TotalRetentionInDays $total -ErrorAction Stop | Out-Null
            Write-Output "  [updated] $($t.Name)"; $updated++
        }
        catch { Write-Output "  [skipped] $($t.Name): $($_.Exception.Message)"; $failed++ }
    }
}

Write-Output "===== Summary: updated=$updated  alreadyCompliant=$compliant  failed=$failed ====="
