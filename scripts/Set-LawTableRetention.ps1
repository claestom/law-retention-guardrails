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

    Within each workspace the table updates are applied in parallel
    (ForEach-Object -Parallel) using the ARM REST API directly (Invoke-RestMethod
    with a shared bearer token), which avoids importing the heavy Az modules into
    every runspace - the main reason -Parallel with Az cmdlets is slow. Use
    -ThrottleLimit to tune concurrency. Workspaces are still processed one at a
    time so per-subscription context switching stays safe.

    Supports -WhatIf to preview changes without applying them.

.PARAMETER ResourceGroupName
    Resource group containing the Log Analytics workspace(s).

.PARAMETER RetentionInDays
    Desired analytics (interactive) retention in days. Use -1 to inherit the
    workspace default. Default: -1.

.PARAMETER TotalRetentionInDays
    Desired total retention in days (analytics + long-term). Use -1 to inherit
    the workspace default (no long-term retention). Default: 730.

.PARAMETER WorkspaceRetentionInDays
    Optional. When greater than 0, also sets the workspace-level default analytics
    retention (Set-AzOperationalInsightsWorkspace) for each workspace in scope.
    Valid range is 30-730. Default -1 leaves the workspace default unchanged.

.PARAMETER WorkspaceName
    Optional. Restrict to a single workspace in the resource group.

.PARAMETER SubscriptionId
    Optional. Sets the Az context to this subscription before running. For
    Subscription scope this also selects which subscription's workspaces are
    enumerated; omit to use the current context subscription.

.PARAMETER ThrottleLimit
    Maximum number of table updates to run concurrently per workspace.
    Default: 10. Lower it if you hit Log Analytics throttling (429) responses.

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

    [ValidateScript({
            if ($_ -eq -1 -or ($_ -ge 4 -and $_ -le 730)) { return $true }
            throw 'RetentionInDays must be -1 (inherit) or an integer 4-730.'
        })]
    [int] $RetentionInDays = -1,

    [ValidateScript({
            $ok = @(-1) + (4..730) + @(1095, 1460, 1826, 2191, 2556, 2922, 3288, 3653, 4018, 4383)
            if ($_ -in $ok) { return $true }
            throw 'TotalRetentionInDays must be -1 (inherit), an integer 4-730, or a full-year value: 1095, 1460, 1826, 2191, 2556, 2922, 3288, 3653, 4018, 4383.'
        })]
    [int] $TotalRetentionInDays = 730,

    [ValidateScript({
            if ($_ -le 0 -or ($_ -ge 30 -and $_ -le 730)) { return $true }
            throw 'WorkspaceRetentionInDays must be -1/0 (unchanged) or an integer 30-730.'
        })]
    [int] $WorkspaceRetentionInDays = -1,

    [string] $WorkspaceName,

    [string] $SubscriptionId,

    [int] $ThrottleLimit = 10
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

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
$wsLabel = if ($WorkspaceRetentionInDays -gt 0) { "$WorkspaceRetentionInDays days" } else { 'unchanged (-1)' }
Write-Host ("Workspace default : {0}" -f $wsLabel) -ForegroundColor Cyan
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

# Enumerate every workspace in a subscription (no Azure Resource Graph dependency).
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
            if ($c.Type -match 'subscriptions') { $ids.Add($c.Name) }
            else { $queue.Enqueue($c.Name) }
        }
    }
    return $ids
}

# ---- Discover workspaces in scope ------------------------------------------
switch ($Scope) {
    'ResourceGroup' {
        if (-not $ResourceGroupName) { throw "Scope 'ResourceGroup' requires -ResourceGroupName." }
        $targets = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName | ForEach-Object {
            [pscustomobject]@{ SubscriptionId = (Get-AzContext).Subscription.Id; ResourceGroupName = $_.ResourceGroupName; Name = $_.Name; RetentionInDays = $_.RetentionInDays }
        }
    }
    'Subscription' { $targets = Get-SubscriptionWorkspaces -SubscriptionId (Get-AzContext).Subscription.Id }
    'ManagementGroup' {
        if (-not $ManagementGroupName) { throw "Scope 'ManagementGroup' requires -ManagementGroupName." }
        $subIds = Get-ManagementGroupSubscriptionIds -ManagementGroup $ManagementGroupName
        $targets = foreach ($s in $subIds) { Get-SubscriptionWorkspaces -SubscriptionId $s }
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

    # Optional: set the workspace-level default retention (one call per workspace).
    if ($WorkspaceRetentionInDays -gt 0) {
        if ($ws.RetentionInDays -eq $WorkspaceRetentionInDays) {
            $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = '(workspace default)'; Status = 'Skipped (already compliant)' })
        }
        elseif ($PSCmdlet.ShouldProcess($ws.Name, "Set workspace default retention=$WorkspaceRetentionInDays")) {
            try {
                Set-AzOperationalInsightsWorkspace -ResourceGroupName $ws.ResourceGroupName -Name $ws.Name -RetentionInDays $WorkspaceRetentionInDays -ErrorAction Stop | Out-Null
                Write-Host ("  [workspace] default retention set to {0}" -f $WorkspaceRetentionInDays) -ForegroundColor Yellow
                $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = '(workspace default)'; Status = 'Updated' })
            }
            catch {
                Write-Host ("  [workspace] failed -> {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
                $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = '(workspace default)'; Status = "Failed: $($_.Exception.Message)" })
            }
        }
        else {
            $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = '(workspace default)'; Status = 'WhatIf (would update)' })
        }
    }

    $tables = Get-AzOperationalInsightsTable -ResourceGroupName $ws.ResourceGroupName -WorkspaceName $ws.Name

    # Classify tables first (cheap, in-memory); only the actual updates hit the API.
    $toUpdate = [System.Collections.Generic.List[object]]::new()
    foreach ($table in $tables) {
        $name = $table.Name

        $retMatch = Test-RetentionMatch -current $table.RetentionInDays -isDefault $table.RetentionInDaysAsDefault -desired $RetentionInDays
        $totMatch = Test-RetentionMatch -current $table.TotalRetentionInDays -isDefault $table.TotalRetentionInDaysAsDefault -desired $TotalRetentionInDays

        if ($retMatch -and $totMatch) {
            $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = $name; Status = 'Skipped (already compliant)' })
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($ws.Name)/$name", "Set retention analytics=$RetentionInDays total=$TotalRetentionInDays")) {
            $toUpdate.Add($table)
        }
        else {
            $results.Add([pscustomobject]@{ Workspace = $ws.Name; Table = $name; Status = 'WhatIf (would update)' })
        }
    }

    # Apply this workspace's updates in parallel via the ARM REST API. Using
    # Invoke-RestMethod (not the Az cmdlet) avoids importing the heavy
    # Az.OperationalInsights module into every parallel runspace, which is the
    # main reason -Parallel with Az cmdlets is slow. One bearer token is fetched
    # per workspace and shared by all workers.
    if ($toUpdate.Count -gt 0) {
        $wsRg   = $ws.ResourceGroupName
        $wsName = $ws.Name
        $wsSub  = if ($ws.SubscriptionId) { $ws.SubscriptionId } else { (Get-AzContext).Subscription.Id }
        $apiVer = '2022-10-01'

        $tokenObj = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
        $armToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
            [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
        }
        else { $tokenObj.Token }

        $updated = $toUpdate | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $table = $_
            $props = @{}
            if ($using:RetentionInDays -eq -1) { $props['retentionInDays'] = $null } else { $props['retentionInDays'] = $using:RetentionInDays }
            if ($using:TotalRetentionInDays -eq -1) { $props['totalRetentionInDays'] = $null } else { $props['totalRetentionInDays'] = $using:TotalRetentionInDays }
            $body = @{ properties = $props } | ConvertTo-Json -Depth 5
            $uri  = "https://management.azure.com/subscriptions/$($using:wsSub)/resourceGroups/$($using:wsRg)/providers/Microsoft.OperationalInsights/workspaces/$($using:wsName)/tables/$($table.Name)?api-version=$($using:apiVer)"
            $headers = @{ Authorization = "Bearer $($using:armToken)" }

            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
                    [pscustomobject]@{ Workspace = $using:wsName; Table = $table.Name; Status = 'Updated' }
                    break
                }
                catch {
                    $code = $null
                    try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                    if ($code -eq 429 -and $attempt -lt 5) { Start-Sleep -Seconds (2 * $attempt); continue }
                    [pscustomobject]@{ Workspace = $using:wsName; Table = $table.Name; Status = "Failed: $($_.Exception.Message)" }
                    break
                }
            }
        }

        foreach ($u in $updated) {
            if ($u.Status -eq 'Updated') {
                Write-Host ("  [updated] {0}" -f $u.Table) -ForegroundColor Yellow
            }
            else {
                Write-Host ("  [skipped] {0} -> {1}" -f $u.Table, ($u.Status -replace '^Failed: ', '')) -ForegroundColor DarkGray
            }
            $results.Add($u)
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

$sw.Stop()
Write-Host ""
Write-Host ("Elapsed time : {0:hh\:mm\:ss\.fff}  (mode: parallel, ThrottleLimit={1})" -f $sw.Elapsed, $ThrottleLimit) -ForegroundColor Magenta

# Emit the detailed results to the pipeline for further processing/export.
$results
