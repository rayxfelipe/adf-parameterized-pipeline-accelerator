#Requires -Version 7.2
. (Join-Path $PSScriptRoot 'Common.ps1')

function Read-SqlRestoreDeployment {
    param([string] $Path = (Join-Path $script:ProjectRoot '.local\sql-restore-deployment.json'))
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "SQL demo settings not found at '$Path'. Run scripts\Deploy-SqlRestoreDemo.ps1 first."
    }
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable
}

function Publish-SqlRestoreAssets {
    param(
        [Parameter(Mandatory)][hashtable] $Deployment,
        [string] $OutputDirectory = (Join-Path $script:ProjectRoot '.local\sql-restore-assets')
    )

    $folder = $OutputDirectory
    $null = New-Item -ItemType Directory -Path $folder -Force
    $link = Get-Content -Raw (Join-Path $script:ProjectRoot 'adf\linkedService\acc_AzureSql.json') | ConvertFrom-Json -AsHashtable
    $link.properties.typeProperties.server = $Deployment.sqlServerFqdn
    $seed = Get-Content -Raw (Join-Path $script:ProjectRoot 'adf\pipeline\acc_SeedSqlBackupDemo.json') | ConvertFrom-Json -AsHashtable
    $seed.properties.parameters.pSourceDatabase.defaultValue = $Deployment.sourceDatabaseName
    $seed.properties.activities[0].typeProperties.scripts[0].text = Get-Content -Raw (Join-Path $script:ProjectRoot 'sql\seed-backup-demo.sql')
    $pipeline = Get-Content -Raw (Join-Path $script:ProjectRoot 'adf\pipeline\acc_ValidateSqlBackup.json') | ConvertFrom-Json -AsHashtable
    $pipeline.properties.parameters.pSqlServerResourceId.defaultValue = $Deployment.sqlServerResourceId
    $pipeline.properties.parameters.pSqlLocation.defaultValue = $Deployment.sqlLocation
    $pipeline.properties.parameters.pSourceDatabase.defaultValue = $Deployment.sourceDatabaseName
    if ($Deployment.ContainsKey('demoRestorePointInTime')) {
        $pipeline.properties.parameters.pRestorePointInTime.defaultValue = $Deployment.demoRestorePointInTime
    }
    $validation = @($pipeline.properties.activities | Where-Object { $_.name -eq 'ValidateRestore' })[0]
    $validation.typeProperties.scripts[0].text = Get-Content -Raw (Join-Path $script:ProjectRoot 'sql\validate-restored-backup.sql')

    foreach ($asset in @(
        @{ definition = $link; kind = 'linkedservices' },
        @{ definition = $seed; kind = 'pipelines' },
        @{ definition = $pipeline; kind = 'pipelines' }
    )) {
        $definition = $asset.definition
        $path = Join-Path $folder "$($definition.name).json"
        $definition | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $response = Invoke-Az -Arguments @(
            'rest', '--method', 'put',
            '--url', "https://management.azure.com$($Deployment.factoryResourceId)/$($asset.kind)/$($definition.name)?api-version=2018-06-01",
            '--body', "@$path", '--subscription', $Deployment.subscriptionId
        )
        if ($response.name -ne $definition.name) { throw "Unexpected publication response for $($definition.name)." }
        Write-Host "Published $($definition.name)"
    }
}

function Set-SqlDemoAdministrator {
    param(
        [Parameter(Mandatory)][hashtable] $Deployment,
        [Parameter(Mandatory)][string] $Login,
        [Parameter(Mandatory)][string] $Sid,
        [ValidateSet('User', 'Group', 'Application')][string] $PrincipalType
    )

    $file = Join-Path ([IO.Path]::GetTempPath()) "sql-demo-admin-$([guid]::NewGuid()).json"
    try {
        @{ properties = @{ administrators = @{
            administratorType = 'ActiveDirectory'
            azureADOnlyAuthentication = $true
            login = $Login
            sid = $Sid
            principalType = $PrincipalType
            tenantId = $Deployment.tenantId
        } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
        $null = Invoke-Az -Arguments @(
            'rest', '--method', 'patch',
            '--url', "https://management.azure.com$($Deployment.sqlServerResourceId)?api-version=2025-01-01",
            '--body', "@$file", '--subscription', $Deployment.subscriptionId
        )
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
        do {
            $server = Invoke-Az -Arguments @(
                'rest', '--method', 'get',
                '--url', "https://management.azure.com$($Deployment.sqlServerResourceId)?api-version=2025-01-01",
                '--subscription', $Deployment.subscriptionId
            )
            if ($server.properties.administrators.sid -eq $Sid) { break }
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw 'SQL Entra administrator update was not confirmed within five minutes. Inspect server administration before proceeding.'
            }
            Start-Sleep -Seconds 10
        } while ($true)
    }
    finally {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
}

function Wait-SqlBackupReady {
    param(
        [Parameter(Mandatory)][hashtable] $Deployment,
        [ValidateRange(5, 120)][int] $TimeoutMinutes = 90
    )
    if (-not $Deployment.ContainsKey('seedCompletedAtUtc')) {
        throw 'No successful seed timestamp is recorded. Run the SQL demo deployment before waiting for backup readiness.'
    }
    $seedTime = [DateTimeOffset]::Parse($Deployment.seedCompletedAtUtc)
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        $source = Invoke-Az -Arguments @(
            'sql', 'db', 'show', '--server', $Deployment.sqlServerName,
            '--name', $Deployment.sourceDatabaseName, '--resource-group', $Deployment.resourceGroupName,
            '--subscription', $Deployment.subscriptionId
        )
        $restoreTime = [DateTimeOffset]::UtcNow.AddMinutes(-10)
        if ($source.ContainsKey('earliestRestoreDate') -and $source.earliestRestoreDate) {
            $earliest = [DateTimeOffset]::Parse($source.earliestRestoreDate)
            if ($earliest -gt $seedTime.AddMinutes(1)) { $restoreTime = $earliest }
            if ($source.status -eq 'Online' -and $restoreTime -ge $earliest -and $restoreTime -gt $seedTime.AddMinutes(1)) {
                Write-Host "Backup window ready. Earliest restore: $earliest; demonstration restore point: $restoreTime"
                return $restoreTime.ToUniversalTime().ToString('o')
            }
            Write-Host "Waiting for a restore point after seeding. Source=$($source.status), earliest=$earliest"
        }
        else {
            Write-Host "Waiting for the initial automatic backup. Source=$($source.status)"
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw "Automatic backup was not ready after $TimeoutMinutes minutes. SQL resources remain provisioned; inspect Azure SQL backup/status and retry."
        }
        Start-Sleep -Seconds 60
    } while ($true)
}
