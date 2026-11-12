#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Az {
    param([Parameter(Mandatory)][string[]] $Arguments)

    # Windows az.cmd needs literal quotes around URL query strings containing '&'.
    if ($IsWindows) {
        $Arguments = @($Arguments | ForEach-Object {
            if ($_ -match '[&|<>]') { '"' + $_ + '"' } else { $_ }
        })
    }
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed (exit $LASTEXITCODE): az $($Arguments -join ' ')"
    }
    if ($result) {
        ($result -join "`n") | ConvertFrom-Json -AsHashtable
    }
}

function Read-Deployment {
    param([string] $Path = (Join-Path $script:ProjectRoot '.local\deployment.json'))

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Deployment settings not found at '$Path'. Run scripts\Deploy.ps1 first."
    }
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable
}

function Invoke-AdfPipeline {
    param(
        [Parameter(Mandatory)][hashtable] $Deployment,
        [Parameter(Mandatory)][string] $PipelineName,
        [Parameter(Mandatory)][hashtable] $Parameters,
        [ValidateRange(1, 120)][int] $TimeoutMinutes = 15,
        [switch] $AllowFailure
    )

    $factoryUrl = "https://management.azure.com$($Deployment.factoryResourceId)"
    $tempFile = Join-Path ([IO.Path]::GetTempPath()) "adf-parameters-$([guid]::NewGuid()).json"
    try {
        $Parameters | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tempFile -Encoding utf8NoBOM
        $response = Invoke-Az -Arguments @(
            'rest', '--method', 'post',
            '--url', "$factoryUrl/pipelines/$PipelineName/createRun?api-version=2018-06-01",
            '--body', "@$tempFile", '--subscription', $Deployment.subscriptionId
        )
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile
        }
    }
    $runId = $response.runId
    Write-Host "Started $PipelineName : $runId"
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        $run = Invoke-Az -Arguments @(
            'rest', '--method', 'get',
            '--url', "$factoryUrl/pipelineruns/${runId}?api-version=2018-06-01",
            '--subscription', $Deployment.subscriptionId
        )
        Write-Host "$PipelineName : $($run.status)"
        if ($run.status -in @('Succeeded', 'Failed', 'Cancelled')) { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            $null = Invoke-Az -Arguments @(
                'rest', '--method', 'post',
                '--url', "$factoryUrl/pipelineruns/$runId/cancel?isRecursive=true&api-version=2018-06-01",
                '--subscription', $Deployment.subscriptionId
            )
            throw "Pipeline $runId exceeded $TimeoutMinutes minutes; recursive cancellation requested."
        }
        Start-Sleep -Seconds 10
    } while ($true)

    $body = @{
        lastUpdatedAfter = [DateTime]::UtcNow.AddDays(-1).ToString('o')
        lastUpdatedBefore = [DateTime]::UtcNow.AddDays(1).ToString('o')
    } | ConvertTo-Json -Compress
    try {
        $body | Set-Content -LiteralPath $tempFile -Encoding utf8NoBOM
        $activities = Invoke-Az -Arguments @(
            'rest', '--method', 'post',
            '--url', "$factoryUrl/pipelineruns/$runId/queryActivityruns?api-version=2018-06-01",
            '--body', "@$tempFile", '--subscription', $Deployment.subscriptionId
        )
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile }
    }
    $result = @{
        pipelineName = $PipelineName
        runId = $runId
        status = $run.status
        message = $run.message
        activities = $activities.value
    }
    if ($run.status -ne 'Succeeded' -and -not $AllowFailure) {
        throw ($result | ConvertTo-Json -Depth 30)
    }
    $result
}

function Send-Samples {
    param([Parameter(Mandatory)][hashtable] $Deployment)

    $sourceRoot = Join-Path $script:ProjectRoot 'samples\landing'
    $samples = @(foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
        @{
            blobName = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName).Replace('\', '/')
            content = Get-Content -Raw -LiteralPath $file.FullName
        }
    })
    $null = Invoke-AdfPipeline -Deployment $Deployment -PipelineName 'acc_SeedSamples' -Parameters @{
        pBlobServiceUrl = $Deployment.blobServiceUrl
        pSamples = $samples
    }
    Write-Host "Uploaded $($samples.Count) synthetic samples through ADF managed identity."
}

function Read-AdfCsv {
    param(
        [Parameter(Mandatory)][hashtable] $Deployment,
        [string] $Container = 'curated',
        [Parameter(Mandatory)][string] $Folder,
        [Parameter(Mandatory)][string] $File,
        [string] $Delimiter = ','
    )

    $preview = Invoke-AdfPipeline -Deployment $Deployment -PipelineName 'acc_PreviewCsv' -Parameters @{
        pContainer = $Container
        pFolder = $Folder
        pFile = $File
        pDelimiter = $Delimiter
    }
    $lookups = @($preview.activities | Where-Object { $_.activityName -eq 'LookupCsv' })
    if ($lookups.Count -ne 1 -or -not $lookups[0].output.ContainsKey('value')) {
        throw "Preview run $($preview.runId) did not return the expected LookupCsv rows."
    }
    @{
        runId = $preview.runId
        rows = @($lookups[0].output.value)
    }
}
