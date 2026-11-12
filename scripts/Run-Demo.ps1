#Requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Summary')]
param(
    [ValidateSet('acc_ProcessBatch', 'acc_CopyCsv')][string] $PipelineName = 'acc_CopyCsv',
    [string] $ParametersFile = '',
    [string] $DeploymentFile = '',
    [Parameter(ParameterSetName = 'Summary')][switch] $PreviewOutput,
    [Parameter(ParameterSetName = 'Detailed')][switch] $Detailed
)
. (Join-Path $PSScriptRoot 'Common.ps1')

$deployment = if ($DeploymentFile) { Read-Deployment -Path $DeploymentFile } else { Read-Deployment }
if (-not $ParametersFile) {
    $example = if ($PipelineName -eq 'acc_CopyCsv') { 'copy' } else { 'batch' }
    $ParametersFile = Join-Path $script:ProjectRoot "examples\$example.parameters.json"
}
$parameters = Get-Content -Raw -LiteralPath $ParametersFile | ConvertFrom-Json -AsHashtable
$result = Invoke-AdfPipeline -Deployment $deployment -PipelineName $PipelineName -Parameters $parameters
if ($Detailed) {
    $result | ConvertTo-Json -Depth 30
    return
}

Write-Host "`nSUCCESS: $PipelineName"
Write-Host "Run ID: $($result.runId)"
$targets = if ($PipelineName -eq 'acc_CopyCsv') {
    @{
        container = $parameters.pSinkContainer
        folder = $parameters.pSinkFolder
        file = $parameters.pSinkFile
        delimiter = $parameters.pDelimiter
    }
}
else {
    foreach ($job in $parameters.pJobs) {
        @{
            container = $parameters.pSinkContainer
            folder = "$($parameters.pOutputRoot)/$($parameters.pRunDate)/$($job.utilityId)/$($job.dataset)"
            file = $job.sinkFile
            delimiter = $job.delimiter
        }
    }
}
foreach ($target in $targets) {
    Write-Host "Output: $($target.container)/$($target.folder)/$($target.file)"
    if ($PreviewOutput) {
        $preview = Read-AdfCsv -Deployment $deployment -Container $target.container `
            -Folder $target.folder -File $target.file -Delimiter $target.delimiter
        Write-Host "Readable output: $($preview.rows.Count) data rows (header not counted)."
        $preview.rows | ForEach-Object { [pscustomobject] $_ } | Format-Table -AutoSize | Out-Host
    }
}
Write-Host "ADF Studio: $($deployment.studioUrl)"
Write-Host 'Next: docs\post-deployment-walkthrough.md'
