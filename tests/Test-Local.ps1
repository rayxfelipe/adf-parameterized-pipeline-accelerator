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
Write-Host 'PASS: parameter bindings, failure propagation, sample paths, and distinct schemas'

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

$local = Join-Path $root '.local'
$null = New-Item -ItemType Directory -Path $local -Force
& az bicep build --file (Join-Path $root 'infra\main.bicep') --outfile (Join-Path $local 'main.json')
if ($LASTEXITCODE -ne 0) { throw 'Bicep build failed.' }
Write-Host 'PASS: Bicep build'
