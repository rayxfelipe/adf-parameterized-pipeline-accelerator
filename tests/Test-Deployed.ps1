#Requires -Version 7.2
[CmdletBinding()]
param([string] $DeploymentFile = '')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Common.ps1')
$deployment = if ($DeploymentFile) { Read-Deployment -Path $DeploymentFile } else { Read-Deployment }
$results = [Collections.Generic.List[object]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-CsvOutput {
    param([hashtable] $Job, [string] $BlobName)

    $lastSlash = $BlobName.LastIndexOf('/')
    $preview = Read-AdfCsv -Deployment $deployment -Container 'curated' `
        -Folder $BlobName.Substring(0, $lastSlash) -File $BlobName.Substring($lastSlash + 1) -Delimiter $Job.delimiter
    $source = Join-Path $script:ProjectRoot ("samples\landing\" + $Job.sourceFolder.Replace('/', '\') + '\' + $Job.sourceFile)
    $expected = @(Import-Csv -LiteralPath $source -Delimiter $Job.delimiter)
    $actual = $preview.rows
    Assert-True ($actual.Count -eq $expected.Count) "Row count mismatch for $BlobName"
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $columns = @($expected[$index].PSObject.Properties.Name)
        Assert-True ($actual[$index].Count -eq $columns.Count) "Column count mismatch for $BlobName"
        foreach ($column in $columns) {
            Assert-True ($actual[$index].ContainsKey($column)) "Missing column $column in $BlobName"
            Assert-True ($actual[$index][$column] -ceq $expected[$index].$column) "Field mismatch at row $index column $column in $BlobName"
        }
    }
    Write-Host "PASS: $BlobName ($($actual.Count) rows, exact schema and field values)"
    @{ blob = $BlobName; rowCount = $actual.Count; valuesMatch = $true; previewRunId = $preview.runId }
}

$storage = Invoke-Az -Arguments @(
    'storage', 'account', 'show', '--name', $deployment.storageAccountName,
    '--resource-group', $deployment.resourceGroupName, '--subscription', $deployment.subscriptionId
)
Assert-True ($storage.publicNetworkAccess -eq 'Disabled') 'Storage public network access must remain disabled.'
Assert-True ($storage.allowSharedKeyAccess -eq $false) 'Storage shared-key access must remain disabled.'
Assert-True ($storage.allowBlobPublicAccess -eq $false) 'Anonymous blob access must remain disabled.'
Assert-True ($storage.networkRuleSet.defaultAction -eq 'Deny') 'Storage firewall must default to deny.'
Write-Host 'PASS: deployed storage public access, keys, anonymous access, and firewall safeguards'

$batch = Get-Content -Raw (Join-Path $script:ProjectRoot 'examples\batch.parameters.json') | ConvertFrom-Json -AsHashtable
$batch.pOutputRoot = "validation/$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$run = Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_ProcessBatch' -Parameters $batch
$results.Add($run)
foreach ($job in $batch.pJobs) {
    $blob = "$($batch.pOutputRoot)/$($batch.pRunDate)/$($job.utilityId)/$($job.dataset)/$($job.sinkFile)"
    $results.Add((Assert-CsvOutput -Job $job -BlobName $blob))
}

$single = Get-Content -Raw (Join-Path $script:ProjectRoot 'examples\copy.parameters.json') | ConvertFrom-Json -AsHashtable
$single.pSinkFolder = "$($batch.pOutputRoot)/renamed"
$single.pSinkFile = 'different-name.csv'
$first = Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_CopyCsv' -Parameters $single
$results.Add($first)
$copyActivity = @($first.activities | Where-Object { $_.activityName -eq 'CopyCsv' })[0]
Assert-True ($copyActivity.output.filesRead -eq 1 -and $copyActivity.output.filesWritten -eq 1) 'Copy metrics must report one file read and written.'
Assert-True ($copyActivity.output.dataRead -gt 0 -and $copyActivity.output.dataWritten -gt 0) 'Copy metrics must report nonzero bytes transferred.'
$results.Add((Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_CopyCsv' -Parameters $single))
$results.Add((Assert-CsvOutput -Job $batch.pJobs[0] -BlobName "$($single.pSinkFolder)/$($single.pSinkFile)"))
Write-Host 'PASS: direct parameter override and deterministic overwrite on rerun'

$missing = $single.Clone()
$missing.pSourceFile = "missing-$([guid]::NewGuid()).csv"
$failed = Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_CopyCsv' -Parameters $missing -AllowFailure
Assert-True ($failed.status -eq 'Failed') 'Missing source must fail.'
$failureActivity = @($failed.activities | Where-Object { $_.activityName -eq 'FailMissingSource' })[0]
Assert-True ($failureActivity.error.errorCode -eq 'SOURCE_FILE_NOT_FOUND') 'Missing-source error code was not surfaced.'
$results.Add($failed)
Write-Host 'PASS: missing source fails with SOURCE_FILE_NOT_FOUND'

$badBatch = $batch.Clone()
$badJob = $batch.pJobs[0].Clone()
$badJob.sourceFile = $missing.pSourceFile
$badBatch.pJobs = @($badJob)
$parentFailed = Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_ProcessBatch' -Parameters $badBatch -AllowFailure
Assert-True ($parentFailed.status -eq 'Failed') 'Parent must fail when a child fails.'
$results.Add($parentFailed)
Write-Host 'PASS: child failure propagates to parent'

$empty = $batch.Clone()
$empty.pJobs = @()
$emptyRun = Invoke-AdfPipeline -Deployment $deployment -PipelineName 'acc_ProcessBatch' -Parameters $empty -AllowFailure
Assert-True ($emptyRun.status -eq 'Failed') 'Empty metadata must not report success.'
$emptyActivity = @($emptyRun.activities | Where-Object { $_.activityName -eq 'FailEmptyJobs' })[0]
Assert-True ($emptyActivity.error.errorCode -eq 'EMPTY_JOB_LIST') 'Empty-job error code was not surfaced.'
$results.Add($emptyRun)
Write-Host 'PASS: empty metadata fails with EMPTY_JOB_LIST'

$report = Join-Path $script:ProjectRoot '.local\test-results.json'
@{ testedAtUtc = [DateTime]::UtcNow.ToString('o'); results = $results.ToArray() } |
    ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $report -Encoding utf8NoBOM
Write-Host "All deployed tests passed. Evidence: $report"
