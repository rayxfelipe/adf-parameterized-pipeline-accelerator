#Requires -Version 7.2
[CmdletBinding()]
param()
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\SqlRestore.Common.ps1')
$deployment = Read-SqlRestoreDeployment
if (-not $deployment.ContainsKey('demoRestorePointInTime')) {
    throw 'Run the SQL demo deployment to validate and record its demonstration backup point before these tests.'
}
$results = [Collections.Generic.List[object]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$server = Invoke-Az -Arguments @(
    'sql', 'server', 'show', '--name', $deployment.sqlServerName,
    '--resource-group', $deployment.resourceGroupName, '--subscription', $deployment.subscriptionId
)
Assert-True ($server.publicNetworkAccess -eq 'Disabled') 'SQL public network access must be disabled.'
Assert-True ($server.administrators.azureAdOnlyAuthentication -eq $true) 'SQL authentication must be Entra-only.'
Assert-True ($server.administrators.sid -eq $deployment.operatorObjectId) 'Bootstrap must restore the operator as SQL administrator.'
$firewall = @(Invoke-Az -Arguments @(
    'sql', 'server', 'firewall-rule', 'list', '--server', $deployment.sqlServerName,
    '--resource-group', $deployment.resourceGroupName, '--subscription', $deployment.subscriptionId
))
Assert-True ($firewall.Count -eq 0) 'Private-only SQL demo must not add public firewall rules.'
Write-Host 'PASS: private SQL, Entra-only authentication, and no retained factory administrator privileges'

$cases = @(
    @{ name = 'pass'; forceFailure = $false; expectedRows = 3; expectedStatus = 'Succeeded'; passed = 1; failedRule = '' },
    @{ name = 'mock-failure'; forceFailure = $true; expectedRows = 3; expectedStatus = 'Failed'; passed = 0; failedRule = 'ForcedDemoFailure' },
    @{ name = 'real-rule-failure'; forceFailure = $false; expectedRows = 99; expectedStatus = 'Failed'; passed = 0; failedRule = 'ExpectedRowCount' }
)

try {
    $windowGuard = Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_ValidateSqlBackup' `
        -Parameters @{ pRestorePointInTime = [DateTimeOffset]::UtcNow.AddDays(1).ToString('o') } -TimeoutMinutes 5 -AllowFailure
    $results.Add(@{ scenario = 'future-restore-point'; run = $windowGuard })
    $failures = @($windowGuard.activities | Where-Object { $_.activityName -eq 'FailInvalidRestorePoint' -and $_.status -eq 'Failed' })
    Assert-True ($windowGuard.status -eq 'Failed' -and $failures.Count -eq 1) 'Future restore points must fail explicitly.'
    Assert-True (@($windowGuard.activities | Where-Object { $_.activityName -eq 'RestoreTemporaryDatabase' }).Count -eq 0) 'Invalid timestamps must not attempt a restore.'
    Write-Host 'PASS: future restore point rejected before database creation'

    foreach ($case in $cases) {
        $run = Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_ValidateSqlBackup' -Parameters @{
            pSqlServerResourceId = $deployment.sqlServerResourceId
            pSqlLocation = $deployment.sqlLocation
            pSourceDatabase = $deployment.sourceDatabaseName
            pExpectedRowCount = $case.expectedRows
            pExpectedAmountTotal = 600
            pForceFailure = $case.forceFailure
        } -TimeoutMinutes 60 -AllowFailure
        $results.Add(@{ scenario = $case.name; run = $run })
        Assert-True ($run.status -eq $case.expectedStatus) "Unexpected pipeline status in $($case.name): $($run.status)"
        $point = @($run.activities | Where-Object { $_.activityName -eq 'SelectRestorePoint' })[0].output.value
        Assert-True ([DateTimeOffset]$point -eq [DateTimeOffset]$deployment.demoRestorePointInTime) 'All scenarios must use the same deployed, verified backup snapshot.'
        $validation = @($run.activities | Where-Object { $_.activityName -eq 'ValidateRestore' -and $_.status -eq 'Succeeded' })
        Assert-True ($validation.Count -eq 1) 'Validation must execute successfully against the actual restored database.'
        $output = $validation[0].output
        Assert-True ($output.resultSetCount -eq 2 -and $output.resultSets[0].rowCount -eq 1) 'Validation must return one summary row and a separate rules result set.'
        $summary = $output.resultSets[0].rows[0]
        $tempName = "acc_restore_$($run.runId.Replace('-', ''))"
        Assert-True ($summary.RestoredDatabase -eq $tempName) 'Validation must query the unique restored database, not the source.'
        Assert-True ($summary.ActualRowCount -eq 3 -and $summary.ActualAmountTotal -eq 600) 'Restored content must match the seeded sample.'
        Assert-True ($summary.ValidationPassed -eq $case.passed) "Unexpected rule result in $($case.name)"
        if ($case.passed -eq 1) {
            Assert-True ($summary.FailedRuleCount -eq 0) 'Pass scenario must have no failed rules.'
            $branch = @($run.activities | Where-Object { $_.activityName -eq 'MockValidationPass' -and $_.status -eq 'Succeeded' })
        }
        else {
            $branch = @($run.activities | Where-Object { $_.activityName -eq 'MockValidationFail_NoEmail' -and $_.status -eq 'Succeeded' })
            $rules = @($output.resultSets[1].rows | Where-Object { $_.RuleName -eq $case.failedRule -and $_.Passed -eq $false })
            Assert-True ($rules.Count -eq 1) "Expected failing rule not found: $($case.failedRule)"
            $failure = @($run.activities | Where-Object { $_.activityName -eq 'DemoFailed' })
            Assert-True ($failure.Count -eq 1 -and $failure[0].error.errorCode -eq 'BACKUP_VALIDATION_FAILED') 'Fail branch must explicitly surface BACKUP_VALIDATION_FAILED.'
        }
        Assert-True ($branch.Count -eq 1) 'Expected If Condition branch did not run.'
        $cleanup = @($run.activities | Where-Object { $_.activityName -eq 'DeleteTemporaryDatabase' -and $_.status -eq 'Succeeded' })
        Assert-True ($cleanup.Count -eq 1) 'Temporary database cleanup must run on both pass and fail.'
        $databases = @(Invoke-Az -Arguments @(
            'sql', 'db', 'list', '--server', $deployment.sqlServerName,
            '--resource-group', $deployment.resourceGroupName, '--subscription', $deployment.subscriptionId
        ))
        Assert-True (@($databases | Where-Object { $_.name -eq $tempName }).Count -eq 0) 'Temporary database must be deleted, not only marked for cleanup.'
        Assert-True (@($databases | Where-Object { $_.name -eq $deployment.sourceDatabaseName -and $_.status -eq 'Online' }).Count -eq 1) 'Source database must remain online.'
        Write-Host "PASS: $($case.name), real restore, correct branch, and temporary database deleted ($($run.runId))"
    }

    $errorName = "acc_ValidateSqlBackup_TestError_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $errorFile = Join-Path $script:ProjectRoot ".local\$errorName.json"
    $errorUrl = "https://management.azure.com$($deployment.factoryResourceId)/pipelines/${errorName}?api-version=2018-06-01"
    $created = $false
    try {
        $fixture = Get-Content -Raw (Join-Path $script:ProjectRoot '.local\sql-restore-assets\acc_ValidateSqlBackup.json') | ConvertFrom-Json -AsHashtable
        $fixture.name = $errorName
        $script = @($fixture.properties.activities | Where-Object { $_.name -eq 'ValidateRestore' })[0]
        $script.typeProperties.scripts[0].text = "THROW 51001, 'Intentional SQL execution error for cleanup verification.', 1;"
        $script.policy.retry = 0
        $fixture | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $errorFile -Encoding utf8NoBOM
        $null = Invoke-Az -Arguments @('rest', '--method', 'put', '--url', $errorUrl, '--body', "@$errorFile", '--subscription', $deployment.subscriptionId)
        $created = $true
        $run = Invoke-AdfPipeline -Deployment $deployment -PipelineName $errorName -Parameters @{} -TimeoutMinutes 60 -AllowFailure
        $results.Add(@{ scenario = 'sql-execution-error'; run = $run })
        Assert-True ($run.status -eq 'Failed') 'An operational SQL error must fail the pipeline.'
        $errors = @($run.activities | Where-Object { $_.activityName -eq 'ValidateRestore' -and $_.status -eq 'Failed' })
        Assert-True ($errors.Count -eq 1 -and $errors[0].error.message -like '*Intentional SQL execution error*') 'Original SQL error must remain visible.'
        $cleanup = @($run.activities | Where-Object { $_.activityName -eq 'DeleteTemporaryDatabase' -and $_.status -eq 'Succeeded' })
        Assert-True ($cleanup.Count -eq 1) 'Cleanup must run when validation and its decision are failed/skipped.'
        $tempName = "acc_restore_$($run.runId.Replace('-', ''))"
        $databases = @(Invoke-Az -Arguments @(
            'sql', 'db', 'list', '--server', $deployment.sqlServerName,
            '--resource-group', $deployment.resourceGroupName, '--subscription', $deployment.subscriptionId
        ))
        Assert-True (@($databases | Where-Object { $_.name -eq $tempName }).Count -eq 0) 'Operational-error scenario must delete its temporary database.'
        Write-Host "PASS: SQL execution error remains visible and temporary database is deleted ($($run.runId))"
    }
    finally {
        if ($created) {
            $null = Invoke-Az -Arguments @('rest', '--method', 'delete', '--url', $errorUrl, '--subscription', $deployment.subscriptionId)
        }
        if (Test-Path -LiteralPath $errorFile) { Remove-Item -LiteralPath $errorFile }
    }
}
finally {
    $report = Join-Path $script:ProjectRoot '.local\sql-restore-test-results.json'
    @{ testedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); results = $results.ToArray() } |
        ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $report -Encoding utf8NoBOM
    Write-Host "SQL restore test evidence: $report"
}
Write-Host 'All SQL restore demo tests passed.'
