#Requires -Version 7.2
[CmdletBinding()]
param(
    [string] $DeploymentFile = '',
    [switch] $PublishOnly,
    [ValidateRange(5, 120)][int] $BackupWaitMinutes = 90
)
. (Join-Path $PSScriptRoot 'SqlRestore.Common.ps1')

if ($PublishOnly) {
    $sql = Read-SqlRestoreDeployment
    $factory = Invoke-Az -Arguments @(
        'rest', '--method', 'get', '--subscription', $sql.subscriptionId,
        '--url', "https://management.azure.com$($sql.factoryResourceId)?api-version=2018-06-01"
    )
    if ($factory.properties.ContainsKey('repoConfiguration') -and $factory.properties.repoConfiguration) {
        throw 'Git-integrated factories must publish generated assets through their normal collaboration branch.'
    }
    Publish-SqlRestoreAssets -Deployment $sql
    return
}

$base = if ($DeploymentFile) { Read-Deployment -Path $DeploymentFile } else { Read-Deployment }
$account = Invoke-Az -Arguments @('account', 'show', '--subscription', $base.subscriptionId)
$operator = Invoke-Az -Arguments @('ad', 'signed-in-user', 'show')
$factory = Invoke-Az -Arguments @(
    'rest', '--method', 'get', '--subscription', $base.subscriptionId,
    '--url', "https://management.azure.com$($base.factoryResourceId)?api-version=2018-06-01"
)
if ($factory.properties.ContainsKey('repoConfiguration') -and $factory.properties.repoConfiguration) {
    throw 'This demo deployer supports live-mode ADF only; use your collaboration branch for a Git-integrated factory.'
}
if (-not $factory.identity.principalId) { throw 'Factory system-assigned managed identity is required.' }
$identity = Invoke-Az -Arguments @('ad', 'sp', 'show', '--id', $factory.identity.principalId)

$local = Join-Path $script:ProjectRoot '.local'
$null = New-Item -ItemType Directory -Path $local -Force
$networkTemplate = Join-Path $local 'sql-managed-network.json'
$sqlTemplate = Join-Path $local 'sql-restore.json'
foreach ($template in @('sql-managed-network', 'sql-restore')) {
    & az bicep build --file (Join-Path $script:ProjectRoot "infra\$template.bicep") --outfile (Join-Path $local "$template.json")
    if ($LASTEXITCODE -ne 0) { throw "Bicep build failed for $template." }
}

# The SQL/private-endpoint what-if needs the managed network to exist first.
$networks = Invoke-Az -Arguments @(
    'rest', '--method', 'get', '--subscription', $base.subscriptionId,
    '--url', "https://management.azure.com$($base.factoryResourceId)/managedVirtualNetworks?api-version=2018-06-01"
)
if (@($networks.value | Where-Object { $_.name -eq 'default' }).Count -eq 0) {
    $argsNetwork = @(
        '--name', 'sql-demo-managed-network', '--resource-group', $base.resourceGroupName,
        '--subscription', $base.subscriptionId, '--template-file', $networkTemplate,
        '--parameters', "factoryName=$($base.factoryName)"
    )
    & az deployment group what-if @argsNetwork --result-format ResourceIdOnly --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Managed-network what-if failed.' }
    $null = Invoke-Az -Arguments (@('deployment', 'group', 'create', '--mode', 'Incremental') + $argsNetwork)
}

$parameters = Join-Path $local 'sql-restore.parameters.json'
@{ parameters = @{
    factoryName = @{ value = $base.factoryName }
    administratorLogin = @{ value = $operator.userPrincipalName }
    administratorObjectId = @{ value = $operator.id }
    tenantId = @{ value = $account.tenantId }
    location = @{ value = $factory.location }
} } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameters -Encoding utf8NoBOM
$argsSql = @(
    '--name', 'sql-backup-validation-demo', '--resource-group', $base.resourceGroupName,
    '--subscription', $base.subscriptionId, '--template-file', $sqlTemplate, '--parameters', "@$parameters"
)
& az deployment group what-if @argsSql --result-format ResourceIdOnly --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'SQL what-if failed; no SQL resources deployed.' }
$result = Invoke-Az -Arguments (@('deployment', 'group', 'create', '--mode', 'Incremental') + $argsSql)
if ($result.properties.provisioningState -ne 'Succeeded') { throw 'SQL infrastructure deployment failed.' }
$outputs = $result.properties.outputs
$sql = $base.Clone()
$sql.sqlServerName = $outputs.sqlServerName.value
$sql.sqlServerResourceId = $outputs.sqlServerResourceId.value
$sql.sqlServerFqdn = $outputs.sqlServerFqdn.value
$sql.sourceDatabaseName = $outputs.sourceDatabaseName.value
$sql.sourceDatabaseResourceId = $outputs.sourceDatabaseResourceId.value
$sql.sqlLocation = $outputs.location.value
$sql.tenantId = $account.tenantId
$sql.operatorLogin = $operator.userPrincipalName
$sql.operatorObjectId = $operator.id

$settings = Join-Path $local 'sql-restore-deployment.json'
if (Test-Path -LiteralPath $settings) {
    $previous = Read-SqlRestoreDeployment
    if ($previous.sqlServerResourceId -ne $sql.sqlServerResourceId) { throw 'Existing SQL settings target a different server.' }
    if ($previous.ContainsKey('seedCompletedAtUtc')) { $sql.seedCompletedAtUtc = $previous.seedCompletedAtUtc }
}
$sql | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settings -Encoding utf8NoBOM

$endpointDeadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
do {
    $connections = @(Invoke-Az -Arguments @(
        'network', 'private-endpoint-connection', 'list', '--id', $sql.sqlServerResourceId,
        '--subscription', $sql.subscriptionId
    ))
    if ($connections.Count -gt 1) { throw 'Unexpected additional SQL private endpoint connections; do not approve unrelated connections.' }
    if ($connections.Count -eq 1) {
        $connection = $connections[0]
        $state = $connection.properties.privateLinkServiceConnectionState.status
        if ($state -eq 'Pending') {
            $null = Invoke-Az -Arguments @(
                'network', 'private-endpoint-connection', 'approve', '--id', $connection.id,
                '--description', 'ADF SQL restore demo private access', '--subscription', $sql.subscriptionId
            )
            Write-Host 'Approved the dedicated ADF SQL private endpoint.'
            break
        }
        if ($state -eq 'Approved') { break }
        throw "SQL private endpoint is $state; inspect the connection."
    }
    if ([DateTimeOffset]::UtcNow -ge $endpointDeadline) { throw 'ADF managed private endpoint connection did not appear within 10 minutes.' }
    Start-Sleep -Seconds 15
} while ($true)

Publish-SqlRestoreAssets -Deployment $sql
if (-not $sql.ContainsKey('seedCompletedAtUtc')) {
    try {
        Set-SqlDemoAdministrator -Deployment $sql -Login $base.factoryName -Sid $identity.appId -PrincipalType Application
        Write-Host 'Factory temporarily administers only the dedicated SQL demo server for bootstrap.'
        $seed = Invoke-AdfPipeline -Deployment $sql -PipelineName 'acc_SeedSqlBackupDemo' -Parameters @{
            pSourceDatabase = $sql.sourceDatabaseName
            pFactoryClientId = $identity.appId
        } -TimeoutMinutes 20
        $seed | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath (Join-Path $local 'sql-seed-results.json') -Encoding utf8NoBOM
        $sql.seedCompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $sql | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settings -Encoding utf8NoBOM
    }
    finally {
        Set-SqlDemoAdministrator -Deployment $sql -Login $operator.userPrincipalName -Sid $operator.id -PrincipalType User
        Write-Host 'Restored the operator as SQL Entra administrator; factory retains only contained SELECT access.'
    }
}
$point = Wait-SqlBackupReady -Deployment $sql -TimeoutMinutes $BackupWaitMinutes
$validation = Invoke-AdfPipeline -Deployment $sql -PipelineName 'acc_ValidateSqlBackup' -Parameters @{
    pRestorePointInTime = $point
    pExpectedRowCount = 3
    pExpectedAmountTotal = 600
    pForceFailure = $false
} -TimeoutMinutes 60 -AllowFailure
$validation | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $local 'sql-initial-validation-results.json') -Encoding utf8NoBOM
if ($validation.status -ne 'Succeeded') {
    throw 'Initial backup restore validation failed. Inspect .local\sql-initial-validation-results.json and the ADF activity errors.'
}
$sql.demoRestorePointInTime = $point
$sql | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settings -Encoding utf8NoBOM
Publish-SqlRestoreAssets -Deployment $sql
Write-Host "SQL restore demo ready: $($sql.sqlServerName) / $($sql.sourceDatabaseName)"
Write-Host 'Run scripts\Run-SqlRestoreDemo.ps1, or trigger acc_ValidateSqlBackup in ADF Studio.'
