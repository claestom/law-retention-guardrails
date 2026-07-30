<#
.SYNOPSIS
    Deploys the "Configure Log Analytics data retention" initiative (DeployIfNotExists)
    and its two member policy definitions, assigns it with a managed identity, grants the
    required role, and starts remediation tasks for existing workspaces and tables.

.DESCRIPTION
    Creates/updates, then assigns and remediates:
      1. Policy definition       : configure-law-workspace-retention  (DeployIfNotExists)
      2. Policy definition       : configure-law-table-retention      (DeployIfNotExists)
      3. Policy set (initiative) : configure-law-data-retention       (references the two above)
      4. Policy assignment       : with a system-assigned managed identity
      5. Role assignment         : Log Analytics Contributor for that identity, at the scope
      6. Remediation tasks       : one per member definition, to fix existing resources

    The initiative JSON ships with placeholder policyDefinitionId tokens
    (__WORKSPACE_DEF_ID__ / __TABLE_DEF_ID__). This script substitutes the real
    resource IDs of the definitions it just created before creating the initiative.

.NOTES
    Includes a subscription guardrail: the script refuses to run against the
    "Visual Studio Enterprise Subscription" and requires an explicit expected
    subscription id. Use -SkipAssignment to only (re)create the definitions and initiative.
#>

[CmdletBinding()]
param(
    # Target subscription id. Defaults to the preferred lab subscription.
    [string] $SubscriptionId = "794194cd-a4b7-4024-970c-9533c4babff0",

    # Optional: deploy to a management group instead of a subscription.
    [string] $ManagementGroupId,

    # Optional: assign at a single resource group (within -SubscriptionId) instead of the whole subscription.
    [string] $ResourceGroupName,

    # Optional: assign at an explicit scope id - a resource group or an individual resource
    # (e.g. a specific Log Analytics workspace resource id). Overrides -ResourceGroupName / -ManagementGroupId
    # for the assignment, role grant and remediation. The definitions/initiative are still created at the
    # subscription (or management group) that contains the scope.
    [string] $Scope,

    # Region for the assignment's managed identity (DeployIfNotExists requires a location).
    [string] $Location = "westeurope",

    # Assignment name.
    [string] $AssignmentName = "law-data-retention",

    # Retention values applied by the assignment.
    [int] $WorkspaceRetentionInDays  = 30,
    [int] $TableRetentionInDays      = 30,
    [int] $TableTotalRetentionInDays = 730,

    # Table-name filter for this assignment (wildcard 'like' patterns). Defaults govern all tables.
    # Example: baseline uses -TableNameNotLike 'App*'; an App Insights overlay uses -TableNameLike 'App*'.
    [string] $TableNameLike    = "*",
    [string] $TableNameNotLike = "~noexclude~",

    # Optional scopes to exclude from this assignment (e.g. a dedicated Sentinel resource group
    # that is governed by its own assignment at 90 days).
    [string[]] $NotScopes,

    # Only create/update the definitions and initiative; skip assignment, role and remediation.
    [switch] $SkipAssignment
)

$ErrorActionPreference = "Stop"

# ---- Guardrail -------------------------------------------------------------
$forbiddenSub = "11e4a1ec-68c0-4790-a7dc-34fc2144ad23"  # Visual Studio Enterprise - never deploy here
if ($SubscriptionId -eq $forbiddenSub) {
    throw "Refusing to deploy to the Visual Studio Enterprise Subscription ($forbiddenSub)."
}

$laContributorRoleId = "92aaf0da-9dab-42b6-94a3-d43ce8d16293"  # Log Analytics Contributor

$repoRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$wsDefFile  = Join-Path $repoRoot "policyDefinitions/configure-law-workspace-retention/azurepolicy.json"
$tblDefFile = Join-Path $repoRoot "policyDefinitions/configure-law-table-retention/azurepolicy.json"
$setFile    = Join-Path $repoRoot "policySetDefinitions/configure-law-data-retention/azurepolicy.json"

foreach ($f in @($wsDefFile, $tblDefFile, $setFile)) {
    if (-not (Test-Path $f)) { throw "File not found: $f" }
}

# ---- Scope selection -------------------------------------------------------
$useMg = -not [string]::IsNullOrWhiteSpace($ManagementGroupId)
if (-not $useMg) {
    az account set --subscription $SubscriptionId | Out-Null
    $current = az account show --query id -o tsv
    if ($current -ne $SubscriptionId) {
        throw "Active subscription ($current) does not match expected ($SubscriptionId). Aborting."
    }
    Write-Host "Deploying to subscription $SubscriptionId" -ForegroundColor Cyan
    $scopeArgs   = @("--subscription", $SubscriptionId)
    $assignScope = "/subscriptions/$SubscriptionId"
} else {
    Write-Host "Deploying to management group $ManagementGroupId" -ForegroundColor Cyan
    $scopeArgs   = @("--management-group", $ManagementGroupId)
    $assignScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
}

# Narrow the assignment scope to a resource group or an individual resource, if requested.
# (Definitions/initiative still live at the subscription/management group above.)
$assignRgName = $null
if (-not [string]::IsNullOrWhiteSpace($Scope)) {
    $assignScope = $Scope
    if ($Scope -match '/resourceGroups/([^/]+)') { $assignRgName = $Matches[1] }
    Write-Host "Assignment scope (explicit): $assignScope" -ForegroundColor Cyan
} elseif (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    if ($useMg) { throw "Use -SubscriptionId (not -ManagementGroupId) together with -ResourceGroupName." }
    $assignScope  = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    $assignRgName = $ResourceGroupName
    Write-Host "Assignment scope (resource group): $assignScope" -ForegroundColor Cyan
}

# ---- Helper: write a JSON blob to a temp file and return an az '@file' arg ---
# Passing large JSON inline to `az ... --rules {json}` makes the CLI treat it as
# "shorthand syntax" and choke on the ' characters in [parameters('...')]. Reading
# from a file (@path) bypasses that parser entirely.
$script:TempJsonFiles = @()
function New-JsonArg {
    param($Object)
    $tmp = [System.IO.Path]::GetTempFileName()
    ($Object | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $tmp -Encoding utf8
    $script:TempJsonFiles += $tmp
    return "@$tmp"
}

try {
    # ---- 1) Workspace-level policy definition -----------------------------
    $wsName = "configure-law-workspace-retention"
    Write-Host "Creating/updating policy definition: $wsName" -ForegroundColor Green
    $wsJson = Get-Content $wsDefFile -Raw | ConvertFrom-Json
    az policy definition create `
        --name $wsName `
        --display-name $wsJson.properties.displayName `
        --description  $wsJson.properties.description `
        --mode         $wsJson.properties.mode `
        --metadata     "category=Monitoring" `
        --rules   (New-JsonArg $wsJson.properties.policyRule) `
        --params  (New-JsonArg $wsJson.properties.parameters) `
        @scopeArgs | Out-Null

    # ---- 2) Table-level policy definition ---------------------------------
    $tblName = "configure-law-table-retention"
    Write-Host "Creating/updating policy definition: $tblName" -ForegroundColor Green
    $tblJson = Get-Content $tblDefFile -Raw | ConvertFrom-Json
    az policy definition create `
        --name $tblName `
        --display-name $tblJson.properties.displayName `
        --description  $tblJson.properties.description `
        --mode         $tblJson.properties.mode `
        --metadata     "category=Monitoring" `
        --rules   (New-JsonArg $tblJson.properties.policyRule) `
        --params  (New-JsonArg $tblJson.properties.parameters) `
        @scopeArgs | Out-Null

    # ---- Resolve the definition resource IDs ------------------------------
    $wsDefId  = az policy definition show --name $wsName  @scopeArgs --query id -o tsv
    $tblDefId = az policy definition show --name $tblName @scopeArgs --query id -o tsv
    Write-Host "Workspace definition id: $wsDefId"
    Write-Host "Table definition id    : $tblDefId"

    # ---- 3) Initiative (policy set definition) ----------------------------
    $setName = "configure-law-data-retention"
    Write-Host "Creating/updating initiative: $setName" -ForegroundColor Green
    $setRaw = (Get-Content $setFile -Raw) `
        -replace "__WORKSPACE_DEF_ID__", $wsDefId `
        -replace "__TABLE_DEF_ID__",     $tblDefId
    $setJson = $setRaw | ConvertFrom-Json

    $setArgs = @(
        "--name", $setName,
        "--display-name", $setJson.properties.displayName,
        "--description",  $setJson.properties.description,
        "--metadata",     "category=Monitoring",
        "--definitions",  (New-JsonArg $setJson.properties.policyDefinitions),
        "--params",       (New-JsonArg $setJson.properties.parameters)
    )
    if ($setJson.properties.policyDefinitionGroups) {
        $setArgs += @("--definition-groups", (New-JsonArg $setJson.properties.policyDefinitionGroups))
    }
    az policy set-definition create @setArgs @scopeArgs | Out-Null

    $setId = az policy set-definition show --name $setName @scopeArgs --query id -o tsv
    Write-Host "Initiative created: $setId" -ForegroundColor Cyan

    if ($SkipAssignment) {
        Write-Host ""
        Write-Host "-SkipAssignment set: definitions and initiative are in place. Assign and remediate it yourself when ready." -ForegroundColor Yellow
        return
    }

    # ---- 4) Assignment (with a system-assigned managed identity) ----------
    Write-Host ""
    Write-Host "Creating/updating assignment: $AssignmentName" -ForegroundColor Green
    $assignParams = [ordered]@{
        effect                    = @{ value = "DeployIfNotExists" }
        workspaceRetentionInDays  = @{ value = $WorkspaceRetentionInDays }
        tableRetentionInDays      = @{ value = $TableRetentionInDays }
        tableTotalRetentionInDays = @{ value = $TableTotalRetentionInDays }
        tableNameLike             = @{ value = $TableNameLike }
        tableNameNotLike          = @{ value = $TableNameNotLike }
    }
    $notScopesArgs = @()
    if ($NotScopes -and $NotScopes.Count -gt 0) { $notScopesArgs = @("--not-scopes") + $NotScopes }
    az policy assignment create `
        --name $AssignmentName `
        --display-name "Configure Log Analytics data retention" `
        --policy-set-definition $setId `
        --scope $assignScope `
        --params (New-JsonArg $assignParams) `
        --mi-system-assigned `
        --location $Location `
        @notScopesArgs | Out-Null

    $assignmentId = az policy assignment show --name $AssignmentName --scope $assignScope --query id -o tsv
    $principalId  = az policy assignment show --name $AssignmentName --scope $assignScope --query identity.principalId -o tsv
    Write-Host "Assignment id: $assignmentId"
    Write-Host "Identity principalId: $principalId"

    # ---- 5) Role assignment: Log Analytics Contributor --------------------
    Write-Host ""
    Write-Host "Granting Log Analytics Contributor to the assignment identity (with retry for AAD propagation)" -ForegroundColor Green
    $granted = $false
    for ($i = 1; $i -le 6 -and -not $granted; $i++) {
        try {
            az role assignment create `
                --assignee-object-id $principalId `
                --assignee-principal-type ServicePrincipal `
                --role $laContributorRoleId `
                --scope $assignScope | Out-Null
            $granted = $true
        } catch {
            Write-Host "  attempt $i failed (identity may not have propagated yet); retrying in 10s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 10
        }
    }
    if (-not $granted) { throw "Could not create the role assignment for principal $principalId at $assignScope." }

    # ---- 6) Remediation tasks (existing resources) ------------------------
    Write-Host ""
    Write-Host "Starting remediation tasks for existing workspaces and tables" -ForegroundColor Green
    # The remediation scope must be AT or BELOW the assignment scope.
    $remScope = @()
    $canRemediate = $true
    if (-not [string]::IsNullOrWhiteSpace($Scope) -and
        $Scope -match '/resourceGroups/(?<rg>[^/]+)/providers/(?<ns>[^/]+)/(?<type>[^/]+)/(?<name>[^/]+)$') {
        # Resource-scoped assignment: remediate at that resource.
        $remScope = @(
            "--resource-group", $Matches.rg,
            "--namespace",      $Matches.ns,
            "--resource-type",  $Matches.type,
            "--resource",       $Matches.name
        )
    } elseif ($assignRgName) {
        $remScope = @("--resource-group", $assignRgName)
    } elseif ($useMg) {
        $remScope = @("--management-group", $ManagementGroupId)
    } elseif (-not [string]::IsNullOrWhiteSpace($Scope)) {
        # An explicit scope we can't map to a remediation scope (e.g. a nested/child resource).
        $canRemediate = $false
    }
    if ($canRemediate) {
        foreach ($ref in @("configureLawWorkspaceRetention", "configureLawTableRetention")) {
            $remName = "remediate-$ref-$((Get-Date).ToString('yyyyMMddHHmmss'))"
            az policy remediation create `
                --name $remName `
                --policy-assignment $assignmentId `
                --definition-reference-id $ref `
                @remScope | Out-Null
            Write-Host "  remediation started: $remName ($ref)"
        }
    } else {
        Write-Host "  Skipping automatic remediation for scope '$Scope' - create remediation tasks in the portal (Policy -> Remediation)." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Done. The initiative is assigned with DeployIfNotExists and remediation is running." -ForegroundColor Cyan
    Write-Host "Track progress in the portal: Policy -> Remediation, or:" -ForegroundColor Yellow
    Write-Host "  az policy remediation list $(@($remScope) -join ' ') -o table"
}
finally {
    foreach ($t in $script:TempJsonFiles) { Remove-Item -LiteralPath $t -ErrorAction SilentlyContinue }
}
