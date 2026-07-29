<#
.SYNOPSIS
    Azure Automation runbook - applies table-level retention (analytics + total) to
    every table in every Log Analytics workspace in the chosen scope.

.DESCRIPTION
    Authenticates with the Automation Account's system-assigned managed identity and
    loops over all workspaces/tables in scope, setting analytics and total retention.
    Idempotent (skips already-compliant tables) and resilient (non-updatable tables
    are logged and skipped).

    Scope can be a single resource group, a whole subscription, or every subscription
    under a management group. Subscription/management-group scope uses Azure Resource
    Graph to enumerate workspaces, then switches Az context per subscription.

    Configuration is read from Automation Variables, so it can be changed AFTER
    deployment without editing the runbook:
      - law-retention-scope-mode      (string: ResourceGroup | Subscription | ManagementGroup)
      - law-retention-resource-group  (string, used when scope = ResourceGroup)
      - law-retention-management-group (string, used when scope = ManagementGroup)
      - law-retention-subscription    (string, optional; used when scope = Subscription to
                                       target a subscription OTHER than the identity's home
                                       one. Empty = the Automation Account's own subscription)
      - law-retention-workspace       (string, empty = all workspaces in scope)
      - law-retention-analytics-days  (int, -1 = same as workspace)
      - law-retention-total-days      (int, e.g. 730; -1 = same as workspace)
      - law-retention-workspace-days  (int, workspace default retention 30-730;
                                       0 or unset = leave the workspace default unchanged)

    Any value passed as a runbook parameter (e.g. from a schedule) overrides the
    matching Automation Variable.

.NOTES
    Runbook type: PowerShell 7.2. Requires Az.Accounts, Az.OperationalInsights and
    (for Subscription/ManagementGroup scope) Az.Resources imported into the
    Automation Account, and the managed identity granted 'Log Analytics Contributor'
    at the matching scope (resource group, subscription, or management group).
#>
param(
    [string] $Scope,                 # ResourceGroup | Subscription | ManagementGroup
    [string] $ResourceGroupName,
    [string] $ManagementGroupName,
    [string] $SubscriptionId,        # optional; Subscription scope target (empty = home sub)
    [string] $WorkspaceName,
    [string] $RetentionInDays,
    [string] $TotalRetentionInDays,
    [string] $WorkspaceRetentionInDays,   # workspace default retention (30-730); empty/0 = leave unchanged
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

$rg     = Resolve-Config -ParamValue $ResourceGroupName    -VariableName 'law-retention-resource-group' -Optional
$wsName = Resolve-Config -ParamValue $WorkspaceName        -VariableName 'law-retention-workspace' -Optional
$ret    = [int](Resolve-Config -ParamValue $RetentionInDays      -VariableName 'law-retention-analytics-days')
$total  = [int](Resolve-Config -ParamValue $TotalRetentionInDays -VariableName 'law-retention-total-days')
$wsRetRaw  = Resolve-Config -ParamValue $WorkspaceRetentionInDays -VariableName 'law-retention-workspace-days' -Optional
$wsRetDays = [string]::IsNullOrWhiteSpace($wsRetRaw) ? -1 : [int]$wsRetRaw

# ---- Validate retention values (fail fast with a clear message) -------------
$allowedTotal = @(-1) + (4..730) + @(1095, 1460, 1826, 2191, 2556, 2922, 3288, 3653, 4018, 4383)
if ($ret -ne -1 -and ($ret -lt 4 -or $ret -gt 730)) {
    throw "law-retention-analytics-days must be -1 or 4-730 (got $ret)."
}
if ($total -notin $allowedTotal) {
    throw "law-retention-total-days must be -1, 4-730, or a full-year value (1095, 1460, 1826, 2191, 2556, 2922, 3288, 3653, 4018, 4383); got $total."
}
if ($wsRetDays -gt 0 -and ($wsRetDays -lt 30 -or $wsRetDays -gt 730)) {
    throw "law-retention-workspace-days must be 30-730 (got $wsRetDays)."
}

$mgName = Resolve-Config -ParamValue $ManagementGroupName  -VariableName 'law-retention-management-group' -Optional
$subId  = Resolve-Config -ParamValue $SubscriptionId       -VariableName 'law-retention-subscription' -Optional
$scopeMode = Resolve-Config -ParamValue $Scope            -VariableName 'law-retention-scope-mode' -Optional
if ([string]::IsNullOrWhiteSpace($scopeMode)) { $scopeMode = 'ResourceGroup' }
$whatIf = ($PreviewOnly -eq 'true')

Write-Output "Scope           : $scopeMode"
Write-Output ("Resource group  : {0}" -f ([string]::IsNullOrWhiteSpace($rg) ? '(n/a)' : $rg))
Write-Output ("Management group : {0}" -f ([string]::IsNullOrWhiteSpace($mgName) ? '(n/a)' : $mgName))
Write-Output ("Workspace filter: {0}" -f ([string]::IsNullOrWhiteSpace($wsName) ? '(all)' : $wsName))
Write-Output "Target retention: analytics=$ret total=$total  (-1 = same as workspace)  PreviewOnly=$whatIf"
Write-Output ("Workspace default: {0}" -f ($wsRetDays -gt 0 ? "$wsRetDays days" : '(unchanged)'))

function Test-RetentionMatch {
    param($current, $isDefault, $desired)
    if ($desired -eq -1) { return [bool] $isDefault }
    return ($current -eq $desired)
}

# Enumerate every workspace in a subscription using only Az.OperationalInsights
# (no Azure Resource Graph dependency). Switches Az context if needed.
function Get-SubscriptionWorkspaces {
    param([string] $SubscriptionId)
    if ($SubscriptionId -and (Get-AzContext).Subscription.Id -ne $SubscriptionId) {
        Set-AzContext -Subscription $SubscriptionId | Out-Null
    }
    $sid = (Get-AzContext).Subscription.Id
    Get-AzOperationalInsightsWorkspace | ForEach-Object {
        [pscustomobject]@{ SubscriptionId = $sid; ResourceGroupName = $_.ResourceGroupName; Name = $_.Name; RetentionInDays = $_.RetentionInDays }
    }
}

# All subscription ids under a management group (recursive), via Az.Resources.
function Get-ManagementGroupSubscriptionIds {
    param([string] $ManagementGroup)
    $ids   = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($ManagementGroup)
    while ($queue.Count -gt 0) {
        $node = Get-AzManagementGroup -GroupId $queue.Dequeue() -Expand -WarningAction SilentlyContinue
        foreach ($c in $node.Children) {
            if ($c.Type -match 'subscriptions') { $ids.Add($c.Name) }   # $c.Name = subscription id
            else { $queue.Enqueue($c.Name) }                            # nested management group
        }
    }
    return $ids
}

switch ($scopeMode) {
    'ResourceGroup' {
        if ([string]::IsNullOrWhiteSpace($rg)) { throw "Scope 'ResourceGroup' requires law-retention-resource-group." }
        $targets = Get-AzOperationalInsightsWorkspace -ResourceGroupName $rg | ForEach-Object {
            [pscustomobject]@{ SubscriptionId = (Get-AzContext).Subscription.Id; ResourceGroupName = $_.ResourceGroupName; Name = $_.Name; RetentionInDays = $_.RetentionInDays }
        }
    }
    'Subscription' {
        $targetSub = [string]::IsNullOrWhiteSpace($subId) ? (Get-AzContext).Subscription.Id : $subId
        Write-Output "Subscription     : $targetSub"
        $targets = Get-SubscriptionWorkspaces -SubscriptionId $targetSub
    }
    'ManagementGroup' {
        if ([string]::IsNullOrWhiteSpace($mgName)) { throw "Scope 'ManagementGroup' requires law-retention-management-group." }
        $subIds = Get-ManagementGroupSubscriptionIds -ManagementGroup $mgName
        Write-Output ("Subscriptions under MG: {0}" -f @($subIds).Count)
        $targets = foreach ($s in $subIds) { Get-SubscriptionWorkspaces -SubscriptionId $s }
    }
    default { throw "Unknown scope '$scopeMode'. Use ResourceGroup, Subscription, or ManagementGroup." }
}

if (-not [string]::IsNullOrWhiteSpace($wsName)) { $targets = $targets | Where-Object { $_.Name -eq $wsName } }
if (-not $targets) { Write-Warning "No Log Analytics workspaces found for scope '$scopeMode'."; return }
Write-Output ("Workspaces in scope: {0}" -f @($targets).Count)

$updated = 0; $compliant = 0; $failed = 0
$wsUpdated = 0; $wsCompliant = 0; $wsFailed = 0
$currentSub = (Get-AzContext).Subscription.Id
foreach ($ws in $targets) {
    if ($ws.SubscriptionId -and $ws.SubscriptionId -ne $currentSub) {
        Set-AzContext -Subscription $ws.SubscriptionId | Out-Null
        $currentSub = $ws.SubscriptionId
    }
    Write-Output "=== [$($ws.SubscriptionId)] $($ws.ResourceGroupName)/$($ws.Name) ==="

    # Optional: set the workspace-level default retention (one call per workspace).
    if ($wsRetDays -gt 0) {
        if ($ws.RetentionInDays -eq $wsRetDays) {
            Write-Output "  [workspace] default retention already $wsRetDays"; $wsCompliant++
        }
        elseif ($whatIf) {
            Write-Output "  [workspace] would set default retention to $wsRetDays"
        }
        else {
            try {
                Set-AzOperationalInsightsWorkspace -ResourceGroupName $ws.ResourceGroupName -Name $ws.Name -RetentionInDays $wsRetDays -ErrorAction Stop | Out-Null
                Write-Output "  [workspace] default retention set to $wsRetDays"; $wsUpdated++
            }
            catch { Write-Output "  [workspace] failed: $($_.Exception.Message)"; $wsFailed++ }
        }
    }

    $tables = Get-AzOperationalInsightsTable -ResourceGroupName $ws.ResourceGroupName -WorkspaceName $ws.Name
    foreach ($t in $tables) {
        $retOk = Test-RetentionMatch -current $t.RetentionInDays      -isDefault $t.RetentionInDaysAsDefault      -desired $ret
        $totOk = Test-RetentionMatch -current $t.TotalRetentionInDays -isDefault $t.TotalRetentionInDaysAsDefault -desired $total
        if ($retOk -and $totOk) { $compliant++; continue }

        if ($whatIf) { Write-Output "  [preview] would update $($t.Name)"; continue }
        try {
            Update-AzOperationalInsightsTable -ResourceGroupName $ws.ResourceGroupName -WorkspaceName $ws.Name `
                -TableName $t.Name -RetentionInDays $ret -TotalRetentionInDays $total -ErrorAction Stop | Out-Null
            Write-Output "  [updated] $($t.Name)"; $updated++
        }
        catch { Write-Output "  [skipped] $($t.Name): $($_.Exception.Message)"; $failed++ }
    }
}

Write-Output "===== Summary (tables): updated=$updated  alreadyCompliant=$compliant  failed=$failed ====="
if ($wsRetDays -gt 0) {
    Write-Output "===== Summary (workspace default): updated=$wsUpdated  alreadyCompliant=$wsCompliant  failed=$wsFailed ====="
}
