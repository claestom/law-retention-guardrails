<#
.SYNOPSIS
    Deploys the "Configure Log Analytics data retention" initiative and its two member
    policy definitions to a subscription (or management group).

.DESCRIPTION
    Creates/updates:
      1. Policy definition  : configure-law-workspace-retention
      2. Policy definition  : configure-law-table-retention
      3. Policy set (initiative) : configure-law-data-retention  (references the two above)

    The initiative JSON ships with placeholder policyDefinitionId tokens
    (__WORKSPACE_DEF_ID__ / __TABLE_DEF_ID__). This script substitutes the real
    resource IDs of the definitions it just created before creating the initiative.

.NOTES
    Includes a subscription guardrail: the script refuses to run against the
    "Visual Studio Enterprise Subscription" and requires an explicit expected
    subscription id.
#>

[CmdletBinding()]
param(
    # Target subscription id. Defaults to the preferred lab subscription.
    [string] $SubscriptionId = "794194cd-a4b7-4024-970c-9533c4babff0",

    # Optional: deploy to a management group instead of a subscription.
    [string] $ManagementGroupId
)

$ErrorActionPreference = "Stop"

# ---- Guardrail -------------------------------------------------------------
$forbiddenSub = "11e4a1ec-68c0-4790-a7dc-34fc2144ad23"  # Visual Studio Enterprise - never deploy here
if ($SubscriptionId -eq $forbiddenSub) {
    throw "Refusing to deploy to the Visual Studio Enterprise Subscription ($forbiddenSub)."
}

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
    $scopeArgs = @("--subscription", $SubscriptionId)
} else {
    Write-Host "Deploying to management group $ManagementGroupId" -ForegroundColor Cyan
    $scopeArgs = @("--management-group", $ManagementGroupId)
}

# ---- Helper: read displayName/description/metadata from a definition file ---
function Get-Prop([string]$path, [string]$name) {
    return (Get-Content $path -Raw | ConvertFrom-Json).properties.$name
}

# ---- 1) Workspace-level policy definition ---------------------------------
$wsName = "configure-law-workspace-retention"
Write-Host "Creating/updating policy definition: $wsName" -ForegroundColor Green
$wsJson = Get-Content $wsDefFile -Raw | ConvertFrom-Json
az policy definition create `
    --name $wsName `
    --display-name $wsJson.properties.displayName `
    --description  $wsJson.properties.description `
    --mode         $wsJson.properties.mode `
    --metadata     "category=Monitoring" `
    --rules   (($wsJson.properties.policyRule)  | ConvertTo-Json -Depth 100 -Compress) `
    --params  (($wsJson.properties.parameters)  | ConvertTo-Json -Depth 100 -Compress) `
    @scopeArgs | Out-Null

# ---- 2) Table-level policy definition -------------------------------------
$tblName = "configure-law-table-retention"
Write-Host "Creating/updating policy definition: $tblName" -ForegroundColor Green
$tblJson = Get-Content $tblDefFile -Raw | ConvertFrom-Json
az policy definition create `
    --name $tblName `
    --display-name $tblJson.properties.displayName `
    --description  $tblJson.properties.description `
    --mode         $tblJson.properties.mode `
    --metadata     "category=Monitoring" `
    --rules   (($tblJson.properties.policyRule) | ConvertTo-Json -Depth 100 -Compress) `
    --params  (($tblJson.properties.parameters) | ConvertTo-Json -Depth 100 -Compress) `
    @scopeArgs | Out-Null

# ---- Resolve the definition resource IDs ----------------------------------
$wsDefId  = az policy definition show --name $wsName  @scopeArgs --query id -o tsv
$tblDefId = az policy definition show --name $tblName @scopeArgs --query id -o tsv
Write-Host "Workspace definition id: $wsDefId"
Write-Host "Table definition id    : $tblDefId"

# ---- 3) Initiative (policy set definition) --------------------------------
$setName = "configure-law-data-retention"
Write-Host "Creating/updating initiative: $setName" -ForegroundColor Green
$setRaw = (Get-Content $setFile -Raw) `
    -replace "__WORKSPACE_DEF_ID__", $wsDefId `
    -replace "__TABLE_DEF_ID__",     $tblDefId
$setJson = $setRaw | ConvertFrom-Json

az policy set-definition create `
    --name $setName `
    --display-name $setJson.properties.displayName `
    --description  $setJson.properties.description `
    --metadata     "category=Monitoring" `
    --definitions  (($setJson.properties.policyDefinitions)      | ConvertTo-Json -Depth 100 -Compress) `
    --params       (($setJson.properties.parameters)            | ConvertTo-Json -Depth 100 -Compress) `
    --definition-groups (($setJson.properties.policyDefinitionGroups) | ConvertTo-Json -Depth 100 -Compress) `
    @scopeArgs | Out-Null

$setId = az policy set-definition show --name $setName @scopeArgs --query id -o tsv
Write-Host ""
Write-Host "Initiative created: $setId" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step - assign it (example, DeployIfNotExists needs a managed identity + location):" -ForegroundColor Yellow
Write-Host "  az policy assignment create ``"
Write-Host "    --name law-retention ``"
Write-Host "    --display-name 'Configure Log Analytics data retention' ``"
Write-Host "    --policy-set-definition $setId ``"
Write-Host "    --scope /subscriptions/$SubscriptionId ``"
Write-Host "    --mi-system-assigned --location westeurope ``"
Write-Host "    -p '{\"workspaceRetentionInDays\":{\"value\":90},\"tableRetentionInDays\":{\"value\":-1},\"tableTotalRetentionInDays\":{\"value\":-1}}'"
Write-Host ""
Write-Host "For DeployIfNotExists remediation, grant the assignment identity the 'Log Analytics Contributor' role, then create a remediation task." -ForegroundColor Yellow
