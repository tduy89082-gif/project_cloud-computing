param(
    [Parameter(Mandatory=$true)][string]$ScheduleAt,
    [string]$Profile = "co3141",
    [string]$Region = "ap-southeast-1",
    [string]$Timezone = "Asia/Ho_Chi_Minh"
)
$ErrorActionPreference = "Stop"
if ($ScheduleAt -notmatch '^20\d{2}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') {
    throw "ScheduleAt must be YYYY-MM-DDTHH:MM:SS local time, for example 2026-11-08T19:30:00."
}
$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {
    function Get-Outputs([string]$StackName) {
        $raw = & aws cloudformation describe-stacks --stack-name $StackName --region $Region --profile $Profile --output json
        if ($LASTEXITCODE -ne 0) { throw "Cannot read outputs for $StackName" }
        $stack = ($raw | ConvertFrom-Json).Stacks[0]
        $out = @{}
        foreach ($item in $stack.Outputs) { $out[$item.OutputKey] = $item.OutputValue }
        return $out
    }
    $infra = Get-Outputs "co3141-shared-infra"
    $service = Get-Outputs "co3141-ecs-service"
    & aws cloudformation deploy `
        --template-file .\cloudformation\scheduler.yaml `
        --stack-name co3141-scheduler `
        --parameter-overrides `
            ProjectName=co3141 `
            ScheduleAt=$ScheduleAt `
            ScheduleTimezone=$Timezone `
            ClusterArn=$($infra.EcsClusterArn) `
            CapacityProviderName=$($infra.EcsCapacityProviderName) `
            WorkerTaskDefinitionArn=$($service.WorkerTaskDefinitionArn) `
            TaskExecutionRoleArn=$($infra.EcsTaskExecutionRoleArn) `
        --capabilities CAPABILITY_NAMED_IAM `
        --region $Region --profile $Profile
    if ($LASTEXITCODE -ne 0) { throw "Scheduler deployment failed. Ensure ScheduleAt is in the future." }
    Write-Host "One-time schedule created for $ScheduleAt $Timezone. After observing it, delete stack co3141-scheduler." -ForegroundColor Green
} finally {
    Pop-Location
}
