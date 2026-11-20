#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Common.ps1')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.json', '*.code-workspace' |
    Where-Object { $_.FullName -notmatch '[\\/](\.local|\.git)[\\/]' }) {
    $null = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
}
Write-Host 'PASS: JSON and workspace syntax'

foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "PowerShell parse errors in $($file.Name): $parseErrors"
}
Write-Host 'PASS: PowerShell syntax'

$copy = Get-Content -Raw (Join-Path $root 'adf\pipeline\acc_CopyCsv.json') | ConvertFrom-Json -AsHashtable
$batch = Get-Content -Raw (Join-Path $root 'adf\pipeline\acc_ProcessBatch.json') | ConvertFrom-Json -AsHashtable
$dataset = Get-Content -Raw (Join-Path $root 'adf\dataset\acc_Csv.json') | ConvertFrom-Json -AsHashtable
$jobs = Get-Content -Raw (Join-Path $root 'examples\batch.parameters.json') | ConvertFrom-Json -AsHashtable
$single = Get-Content -Raw (Join-Path $root 'examples\copy.parameters.json') | ConvertFrom-Json -AsHashtable
$checkFile = Get-Content -Raw (Join-Path $root 'adf\pipeline\acc_CheckFileExists.json') | ConvertFrom-Json -AsHashtable
$checkParameters = Get-Content -Raw (Join-Path $root 'examples\check-file-exists.parameters.json') | ConvertFrom-Json -AsHashtable

foreach ($reference in [regex]::Matches(($checkFile | ConvertTo-Json -Depth 30), 'pipeline\(\)\.parameters\.(\w+)')) {
    $name = $reference.Groups[1].Value
    Assert-True ($checkFile.properties.parameters.ContainsKey($name)) "Undeclared file-check parameter: $name"
    Assert-True ($checkParameters.ContainsKey($name)) "File-check example missing parameter: $name"
}
$checkBinding = $checkFile.properties.activities[0].typeProperties.dataset
Assert-True ($checkBinding.referenceName -eq $dataset.name) 'File check must reuse the existing dataset.'
foreach ($name in $dataset.properties.parameters.Keys) {
    Assert-True ($checkBinding.parameters.ContainsKey($name)) "File check missing dataset parameter: $name"
}
$checkSource = Join-Path $root ("samples\landing\" + $checkParameters.pFolder.Replace('/', '\') + '\' + $checkParameters.pFile)
Assert-True (Test-Path -LiteralPath $checkSource) 'File-check example must target an existing sample.'

$references = [regex]::Matches(($copy | ConvertTo-Json -Depth 50), 'pipeline\(\)\.parameters\.(\w+)')
foreach ($reference in $references) {
    Assert-True ($copy.properties.parameters.ContainsKey($reference.Groups[1].Value)) "Undeclared copy parameter: $reference"
}
$childCall = $batch.properties.activities[1].typeProperties.activities[0]
Assert-True ($childCall.typeProperties.waitOnCompletion -eq $true) 'Parent must propagate child failures.'
Assert-True ($childCall.typeProperties.parameters.Count -eq $copy.properties.parameters.Count) 'Parent must bind every child parameter.'
foreach ($name in $copy.properties.parameters.Keys) {
    Assert-True ($childCall.typeProperties.parameters.ContainsKey($name)) "Parent missing child parameter $name"
    Assert-True ($single.ContainsKey($name)) "Single-copy example missing parameter $name"
}
foreach ($reference in [regex]::Matches(($dataset | ConvertTo-Json -Depth 30), 'dataset\(\)\.(\w+)')) {
    Assert-True ($dataset.properties.parameters.ContainsKey($reference.Groups[1].Value)) "Undeclared dataset parameter: $reference"
}
Assert-True ($copy.properties.activities[1].typeProperties.ifFalseActivities[0].typeProperties.errorCode -eq 'SOURCE_FILE_NOT_FOUND') 'Missing source must fail explicitly.'
Assert-True ($batch.properties.activities[0].typeProperties.ifTrueActivities[0].typeProperties.errorCode -eq 'EMPTY_JOB_LIST') 'Empty batch must fail explicitly.'

$targets = [Collections.Generic.HashSet[string]]::new()
$schemas = [Collections.Generic.HashSet[string]]::new()
foreach ($job in $jobs.pJobs) {
    $source = Join-Path $root ("samples\landing\" + $job.sourceFolder.Replace('/', '\') + '\' + $job.sourceFile)
    Assert-True (Test-Path -LiteralPath $source) "Sample source missing: $source"
    $rows = @(Import-Csv -LiteralPath $source -Delimiter $job.delimiter)
    Assert-True ($rows.Count -gt 0) "Sample must have records: $source"
    $null = $schemas.Add(($rows[0].PSObject.Properties.Name -join ','))
    $target = "$($jobs.pOutputRoot)/$($jobs.pRunDate)/$($job.utilityId)/$($job.dataset)/$($job.sinkFile)"
    Assert-True ($targets.Add($target)) "Duplicate sink target: $target"
}
Assert-True ($schemas.Count -gt 1) 'Demo must demonstrate reuse across different CSV schemas.'
Write-Host 'PASS: copy and file-check parameter bindings, failure propagation, sample paths, and distinct schemas'

& {
    function Invoke-AdfPipeline {
        @{
            runId = 'preview-test'
            activities = @(
                @{ activityName = 'LookupCsv'; output = @{ value = @(@{ id = 'DEMO-1' }) } }
            )
        }
    }
    $preview = Read-AdfCsv -Deployment @{} -Folder 'sample' -File 'sample.csv'
    Assert-True ($preview.rows.Count -eq 1 -and $preview.rows[0].id -ceq 'DEMO-1') 'Preview must preserve row values and single-row array shape.'

    function Invoke-AdfPipeline {
        @{ runId = 'malformed-preview'; activities = @(@{ activityName = 'LookupCsv'; output = @{} }) }
    }
    $rejected = $false
    try {
        $null = Read-AdfCsv -Deployment @{} -Folder 'sample' -File 'sample.csv'
    }
    catch {
        if ($_.Exception.Message -notlike '*did not return the expected LookupCsv rows*') { throw }
        $rejected = $true
    }
    Assert-True $rejected 'Preview must reject a successful run with missing row output.'
}
Write-Host 'PASS: preview row shape and malformed-output rejection'

$sqlPipeline = Get-Content -Raw (Join-Path $root 'adf\pipeline\acc_ValidateSqlBackup.json') | ConvertFrom-Json -AsHashtable
foreach ($reference in [regex]::Matches(($sqlPipeline | ConvertTo-Json -Depth 100), 'pipeline\(\)\.parameters\.(\w+)')) {
    Assert-True ($sqlPipeline.properties.parameters.ContainsKey($reference.Groups[1].Value)) "Undeclared SQL restore parameter: $reference"
}
$cleanup = @($sqlPipeline.properties.activities | Where-Object { $_.name -eq 'DeleteTemporaryDatabase' })[0]
foreach ($name in @('WaitForRestore', 'CheckRestoreSucceeded', 'ValidateRestore', 'CaptureValidationSummary', 'IfValidationPassed')) {
    $dependency = @($cleanup.dependsOn | Where-Object { $_.activity -eq $name })
    Assert-True ($dependency.Count -eq 1 -and 'Completed' -in $dependency[0].dependencyConditions -and 'Skipped' -in $dependency[0].dependencyConditions) "Cleanup must handle failures/skips after $name."
}
Assert-True ($cleanup.typeProperties.url.value -match "variables\('vTemporaryDatabase'\)") 'Cleanup must target only the generated temporary database.'
Assert-True ($cleanup.typeProperties.url.value -notmatch 'pSourceDatabase') 'Cleanup must never target the source database.'

& {
    . (Join-Path $root 'scripts\Common.ps1')
    function Invoke-Az {
        param([string[]] $Arguments)
        $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1]
        if ($url -match '/createRun\?') { return @{ runId = 'paged-test' } }
        if ($url -notmatch '/queryActivityruns\?') { return @{ status = 'Failed'; message = 'Late SQL error' } }
        $request = Get-Content -Raw ($Arguments[[Array]::IndexOf($Arguments, '--body') + 1].Substring(1)) | ConvertFrom-Json -AsHashtable
        if (-not $request.ContainsKey('continuationToken')) {
            return @{ value = @(@{ activityName = 'WaitBeforeStatusCheck'; status = 'Succeeded' }); continuationToken = 'next-page' }
        }
        Assert-True ($request.continuationToken -eq 'next-page') 'Activity query must forward the server continuation token.'
        @{ value = @(@{ activityName = 'ValidateRestore'; status = 'Failed'; error = @{ errorCode = 'SQL_TEST_FAILURE' } }); continuationToken = $null }
    }
    $run = Invoke-AdfPipeline -Deployment @{ factoryResourceId = '/example'; subscriptionId = 'example' } `
        -PipelineName 'paged-test' -Parameters @{} -AllowFailure
    Assert-True ($run.activities.Count -eq 2 -and $run.activities[1].error.errorCode -eq 'SQL_TEST_FAILURE') 'Paged queries must retain late activity errors after polling activities.'
}
Write-Host 'PASS: complete activity-run pagination and late failure evidence'

& {
    . (Join-Path $root 'scripts\SqlRestore.Common.ps1')
    $published = [Collections.Generic.List[hashtable]]::new()
    function Invoke-Az {
        param([string[]] $Arguments)
        $bodyIndex = [Array]::IndexOf($Arguments, '--body') + 1
        $definition = Get-Content -Raw -LiteralPath $Arguments[$bodyIndex].Substring(1) | ConvertFrom-Json -AsHashtable
        $published.Add($definition)
        @{ name = $definition.name }
    }
    $testDeployment = @{
        sqlServerFqdn = 'example.database.windows.net'
        sqlServerResourceId = '/subscriptions/example/resourceGroups/example/providers/Microsoft.Sql/servers/example'
        sqlLocation = 'westus2'
        sourceDatabaseName = 'acc_BackupSource'
        factoryResourceId = '/subscriptions/example/resourceGroups/example/providers/Microsoft.DataFactory/factories/example'
        subscriptionId = 'example'
        demoRestorePointInTime = '2026-01-01T00:00:00Z'
    }
    $testFolder = Join-Path $root ".local\sql-publisher-test-$([guid]::NewGuid())"
    try {
        Publish-SqlRestoreAssets -Deployment $testDeployment -OutputDirectory $testFolder
        Assert-True ($published.Count -eq 3) 'SQL publisher must deploy one linked service and two pipelines.'
        $generated = @($published | Where-Object { $_.name -eq 'acc_ValidateSqlBackup' })[0]
        $script = @($generated.properties.activities | Where-Object { $_.name -eq 'ValidateRestore' })[0]
        Assert-True ($script.typeProperties.scripts[0].text -ceq (Get-Content -Raw (Join-Path $root 'sql\validate-restored-backup.sql'))) 'Published pipeline must embed the editable SQL exactly.'
        Assert-True ($generated.properties.parameters.pSqlServerResourceId.defaultValue -eq $testDeployment.sqlServerResourceId) 'Published server default must match the deployment.'
        Assert-True ([DateTimeOffset]$generated.properties.parameters.pRestorePointInTime.defaultValue -eq [DateTimeOffset]$testDeployment.demoRestorePointInTime) 'Published backup point must match the verified demonstration snapshot.'
    }
    finally {
        foreach ($name in @('acc_AzureSql', 'acc_SeedSqlBackupDemo', 'acc_ValidateSqlBackup')) {
            $file = Join-Path $testFolder "$name.json"
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
        }
        if (Test-Path -LiteralPath $testFolder) { Remove-Item -LiteralPath $testFolder }
    }
}
Write-Host 'PASS: SQL restore parameter bindings, error-path cleanup, and editable SQL publication'

$local = Join-Path $root '.local'
$null = New-Item -ItemType Directory -Path $local -Force
& az bicep build --file (Join-Path $root 'infra\main.bicep') --outfile (Join-Path $local 'main.json')
if ($LASTEXITCODE -ne 0) { throw 'Bicep build failed.' }
Write-Host 'PASS: Bicep build'
foreach ($template in @('sql-managed-network', 'sql-restore')) {
    & az bicep build --file (Join-Path $root "infra\$template.bicep") --outfile (Join-Path $local "$template.json")
    if ($LASTEXITCODE -ne 0) { throw "Bicep build failed for $template." }
}
Write-Host 'PASS: optional SQL restore Bicep builds'
