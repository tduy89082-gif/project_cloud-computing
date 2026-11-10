param(
    [Parameter(Mandatory=$true)][ValidateSet("binpack", "spread")][string]$Strategy,
    [int]$Count = 10,
    [string]$Profile = "co3141",
    [string]$Region = "ap-southeast-1"
)
$ErrorActionPreference = "Stop"

foreach ($name in @("ECS_CLUSTER", "ECS_WORKER_TASK", "ECS_CAPACITY_PROVIDER")) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Set `$env:$name before running this script."
    }
}
if ($Count -lt 1 -or $Count -gt 10) { throw "Count must be between 1 and 10 for one RunTask request." }

$field = if ($Strategy -eq "binpack") { "cpu" } else { "instanceId" }
$capacity = "capacityProvider=$($env:ECS_CAPACITY_PROVIDER),weight=1"
$overrideFile = Join-Path $PSScriptRoot "..\overrides\worker-120.json"

Write-Host "Launching $Count worker tasks with $Strategy ($field)" -ForegroundColor Cyan
$json = & aws ecs run-task `
    --cluster $env:ECS_CLUSTER `
    --task-definition $env:ECS_WORKER_TASK `
    --capacity-provider-strategy $capacity `
    --count $Count `
    --placement-strategy "type=$Strategy,field=$field" `
    --overrides "file://$overrideFile" `
    --region $Region `
    --profile $Profile `
    --output json
if ($LASTEXITCODE -ne 0) { throw "ECS RunTask failed. Check the profile, capacity provider and task definition." }
$result = $json | ConvertFrom-Json

if ($result.failures -and $result.failures.Count -gt 0) {
    $result.failures | Format-List | Out-String | Write-Error
}
$arns = @($result.tasks | ForEach-Object { $_.taskArn })
if ($arns.Count -eq 0) { throw "No tasks were placed. Check ECS capacity, CPU/memory and IAM." }

Write-Host "Started $($arns.Count) task(s). Waiting for placement details..." -ForegroundColor Cyan
$description = $null
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $descJson = & aws ecs describe-tasks `
        --cluster $env:ECS_CLUSTER `
        --tasks $arns `
        --region $Region --profile $Profile --output json
    if ($LASTEXITCODE -ne 0) { throw "Could not describe ECS tasks." }
    $description = $descJson | ConvertFrom-Json
    $ready = @($description.tasks | Where-Object { $_.containerInstanceArn }).Count
    if ($ready -ge $arns.Count) { break }
    Start-Sleep -Seconds 4
}

$containerArns = @($description.tasks | Where-Object { $_.containerInstanceArn } | Select-Object -ExpandProperty containerInstanceArn -Unique)
Write-Host "Task placement:" -ForegroundColor Green
$description.tasks | Select-Object taskArn,lastStatus,containerInstanceArn | Format-Table -AutoSize

if ($containerArns.Count -gt 0) {
    $hostsJson = & aws ecs describe-container-instances `
        --cluster $env:ECS_CLUSTER `
        --container-instances $containerArns `
        --region $Region --profile $Profile --output json
    if ($LASTEXITCODE -eq 0) {
        ($hostsJson | ConvertFrom-Json).containerInstances |
            Select-Object containerInstanceArn,ec2InstanceId,status |
            Format-Table -AutoSize
    }
}
Write-Host "Distinct EC2 hosts observed: $($containerArns.Count)" -ForegroundColor Green
Write-Host "Wait for the 120-second workers to finish before starting the next strategy."
