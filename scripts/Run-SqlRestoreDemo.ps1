#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch] $ForceFailure,
    [ValidateRange(0, 2147483647)][int] $ExpectedRowCount = 3,
    [ValidateRange(0, 2147483647)][int] $ExpectedAmountTotal = 600,
    [string] $RestorePointInTime = ''
)
. (Join-Path $PSScriptRoot 'SqlRestore.Common.ps1')
$deployment = Read-SqlRestoreDeployment
$parameters = @{
    pSqlServerResourceId = $deployment.sqlServerResourceId
    pSqlLocation = $deployment.sqlLocation
    pSourceDatabase = $deployment.sourceDatabaseName
    pExpectedRowCount = $ExpectedRowCount
    pExpectedAmountTotal = $ExpectedAmountTotal
    pForceFailure = [bool] $ForceFailure
}
if ($PSBoundParameters.ContainsKey('RestorePointInTime')) {
    $parameters.pRestorePointInTime = $RestorePointInTime
}
$run = Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_ValidateSqlBackup' -Parameters $parameters -TimeoutMinutes 60 -AllowFailure
$report = Join-Path $script:ProjectRoot '.local\sql-restore-last-run.json'
$run | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $report -Encoding utf8NoBOM
$validation = @($run.activities | Where-Object { $_.activityName -eq 'ValidateRestore' -and $_.status -eq 'Succeeded' })
if ($validation.Count -eq 1) {
    foreach ($set in $validation[0].output.resultSets) {
        $set.rows | ForEach-Object { [pscustomobject] $_ } | Format-Table -AutoSize | Out-Host
    }
}
elseif ($run.status -eq 'Succeeded') {
    throw "Successful run $($run.runId) did not return exactly one successful validation activity. Inspect $report."
}
Write-Host "Run: $($run.runId), status: $($run.status)"
Write-Host "Evidence: $report"
if ($run.status -ne 'Succeeded') {
    throw "SQL backup validation run $($run.runId) failed. With -ForceFailure this is intentional; inspect DemoFailed and original activity errors."
}
