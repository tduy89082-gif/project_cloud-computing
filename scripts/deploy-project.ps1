param(
    [Parameter(Mandatory=$true)][string]$AllowedIngressCidr,
    [string]$Profile = "co3141",
    [string]$Region = "ap-southeast-1",
    [string]$ImageTag = "v1",
    [string]$InstanceType = "t3.small"
)
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {
    function Invoke-Aws {
        param([string[]]$ArgsList)
        & aws @ArgsList
        if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: aws $($ArgsList -join ' ')" }
    }
    function Get-StackOutputs {
        param([string]$StackName)
        $raw = & aws cloudformation describe-stacks --stack-name $StackName --region $Region --profile $Profile --output json
        if ($LASTEXITCODE -ne 0) { throw "Could not read outputs for $StackName" }
        $stack = ($raw | ConvertFrom-Json).Stacks[0]
        $map = @{}
        foreach ($item in $stack.Outputs) { $map[$item.OutputKey] = $item.OutputValue }
        return $map
    }

    # Validate local template syntax before deploying anything.
    foreach ($template in @(
        ".\cloudformation\data-foundation.yaml",
        ".\cloudformation\shared-infra.yaml",
        ".\cloudformation\ecs-service.yaml",
        ".\cloudformation\orchestration.yaml",
        ".\cloudformation\batch.yaml",
        ".\cloudformation\scheduler.yaml"
    )) {
        Invoke-Aws @("cloudformation", "validate-template", "--template-body", "file://$template", "--region", $Region, "--profile", $Profile)
    }

    # Confirm that this profile points at the intended AWS account.
    Invoke-Aws @("sts", "get-caller-identity", "--profile", $Profile)

    # 1) Data foundation: ECR, S3, DynamoDB, CloudWatch Logs.
    Invoke-Aws @("cloudformation", "deploy", "--template-file", ".\cloudformation\data-foundation.yaml", "--stack-name", "co3141-data-foundation", "--parameter-overrides", "ProjectName=co3141", "--region", $Region, "--profile", $Profile)
    $data = Get-StackOutputs "co3141-data-foundation"

    # 2) Build and push one immutable image.
    & (Join-Path $PSScriptRoot "build-push.ps1") -Profile $Profile -Region $Region -Repository "co3141-workload" -Tag $ImageTag
    if ($LASTEXITCODE -ne 0) { throw "Image build/push failed." }
    $imageUri = "$($data.RepositoryUri):$ImageTag"

    # 3) Shared VPC, ECS cluster, EC2 Auto Scaling Group/capacity provider and ALB.
    Invoke-Aws @("cloudformation", "deploy", "--template-file", ".\cloudformation\shared-infra.yaml", "--stack-name", "co3141-shared-infra", "--parameter-overrides", "ProjectName=co3141", "AllowedIngressCidr=$AllowedIngressCidr", "InstanceType=$InstanceType", "--capabilities", "CAPABILITY_NAMED_IAM", "--region", $Region, "--profile", $Profile)
    $infra = Get-StackOutputs "co3141-shared-infra"

    # 4) API and worker definitions, API service and service CPU target tracking.
    Invoke-Aws @("cloudformation", "deploy", "--template-file", ".\cloudformation\ecs-service.yaml", "--stack-name", "co3141-ecs-service", "--parameter-overrides", "ProjectName=co3141", "ClusterName=$($infra.EcsClusterName)", "CapacityProviderName=$($infra.EcsCapacityProviderName)", "TargetGroupArn=$($infra.ApiTargetGroupArn)", "ImageUri=$imageUri", "TaskExecutionRoleArn=$($infra.EcsTaskExecutionRoleArn)", "LogGroupName=$($data.WorkloadLogGroupName)", "--region", $Region, "--profile", $Profile)
    $service = Get-StackOutputs "co3141-ecs-service"

    # 5) Idempotency Lambdas and Step Functions ECS worker workflow.
    Invoke-Aws @("cloudformation", "deploy", "--template-file", ".\cloudformation\orchestration.yaml", "--stack-name", "co3141-orchestration", "--parameter-overrides", "ProjectName=co3141", "IdempotencyTableName=$($data.IdempotencyTableName)", "ClusterArn=$($infra.EcsClusterArn)", "CapacityProviderName=$($infra.EcsCapacityProviderName)", "WorkerTaskDefinitionArn=$($service.WorkerTaskDefinitionArn)", "TaskExecutionRoleArn=$($infra.EcsTaskExecutionRoleArn)", "--capabilities", "CAPABILITY_NAMED_IAM", "--region", $Region, "--profile", $Profile)
    $orchestration = Get-StackOutputs "co3141-orchestration"

    Write-Host "Core deployment complete." -ForegroundColor Green
    Write-Host "API URL: http://$($infra.AlbDnsName)"
    Write-Host "ECS cluster: $($infra.EcsClusterName)"
    Write-Host "ECS capacity provider: $($infra.EcsCapacityProviderName)"
    Write-Host "Auto Scaling Group: $($infra.EcsAutoScalingGroupName)"
    Write-Host "Worker task definition: $($service.WorkerTaskDefinitionArn)"
    Write-Host "Step Functions state machine: $($orchestration.StateMachineArn)"
    Write-Host "Next: run scripts/test-api.ps1, run the placement experiment, and inspect the state machine." 
} finally {
    Pop-Location
}
