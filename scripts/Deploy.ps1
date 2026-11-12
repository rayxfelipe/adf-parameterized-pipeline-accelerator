#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[\w().-]+$')][string] $ResourceGroupName,
    [string] $Location = 'westus2',
    [ValidatePattern('^[a-z0-9]{3,9}$')][string] $NamePrefix = 'adfparam',
    [string] $ExistingFactoryName = '',
    [switch] $Preview,
    [switch] $SkipSeed
)
. (Join-Path $PSScriptRoot 'Common.ps1')

$null = Invoke-Az -Arguments @('account', 'show', '--subscription', $SubscriptionId)
if ($ExistingFactoryName) {
    $existing = Invoke-Az -Arguments @(
        'resource', 'show', '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.DataFactory/factories', '--name', $ExistingFactoryName,
        '--subscription', $SubscriptionId
    )
    if (-not $existing.identity -or -not $existing.identity.principalId) {
        throw 'Existing factory must have a system-assigned managed identity enabled.'
    }
    if ($existing.properties.repoConfiguration) {
        throw 'This existing factory uses Git integration. Import the adf folder into its collaboration branch instead; see README.'
    }
}

$template = Join-Path $script:ProjectRoot 'infra\main.bicep'
$localDirectory = Join-Path $script:ProjectRoot '.local'
$null = New-Item -ItemType Directory -Path $localDirectory -Force
$compiledTemplate = Join-Path $localDirectory 'main.json'
& az bicep build --file $template --outfile $compiledTemplate
if ($LASTEXITCODE -ne 0) { throw 'Bicep build failed.' }

$groupExists = Invoke-Az -Arguments @('group', 'exists', '--name', $ResourceGroupName, '--subscription', $SubscriptionId)
if (-not $groupExists) {
    if ($Preview) {
        throw 'Preview requires an existing resource group. Create a dedicated empty resource group first, or run Deploy.ps1 without -Preview.'
    }
    $null = Invoke-Az -Arguments @(
        'group', 'create', '--name', $ResourceGroupName,
        '--location', $Location, '--subscription', $SubscriptionId,
        '--tags', 'project=adf-parameterized-pipeline-accelerator', 'environment=demo'
    )
}
$parameters = @{
    location = @{ value = $Location }
    namePrefix = @{ value = $NamePrefix }
    existingFactoryName = @{ value = $ExistingFactoryName }
    enableSampleSeeding = @{ value = -not $SkipSeed }
}
$parameterPath = Join-Path $localDirectory 'deploy.parameters.json'
@{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = $parameters
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM

$deploymentArguments = @(
    '--name', 'adf-parameterized-accelerator', '--resource-group', $ResourceGroupName,
    '--template-file', $compiledTemplate, '--parameters', "@$parameterPath",
    '--subscription', $SubscriptionId
)
& az deployment group what-if @deploymentArguments --result-format ResourceIdOnly --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Deployment what-if failed; no resources were deployed.' }
if ($Preview) { return }

$result = Invoke-Az -Arguments (@('deployment', 'group', 'create', '--mode', 'Incremental') + $deploymentArguments)
if ($result.properties.provisioningState -ne 'Succeeded') {
    throw "Deployment failed: $($result | ConvertTo-Json -Depth 30)"
}
$outputs = $result.properties.outputs
$deployment = @{
    subscriptionId = $SubscriptionId
    resourceGroupName = $ResourceGroupName
    factoryName = $outputs.factoryName.value
    factoryResourceId = $outputs.factoryResourceId.value
    storageAccountName = $outputs.storageAccountName.value
    blobServiceUrl = $outputs.blobServiceUrl.value
    studioUrl = $outputs.studioUrl.value
}
$deploymentPath = Join-Path $localDirectory 'deployment.json'
$deployment | ConvertTo-Json | Set-Content -LiteralPath $deploymentPath -Encoding utf8NoBOM
Write-Host "Deployment settings saved locally: $deploymentPath"

if (-not $SkipSeed) {
    Send-Samples -Deployment $deployment
}
Write-Host "ADF Studio: $($deployment.studioUrl)"
