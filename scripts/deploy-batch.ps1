param(
    [string]$Profile = "co3141",
    [string]$Region = "ap-southeast-1",
    [string]$ImageTag = "v1"
)
$ErrorActionPreference = "Stop"
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
    $data = Get-Outputs "co3141-data-foundation"
    $infra = Get-Outputs "co3141-shared-infra"
    $imageUri = "$($data.RepositoryUri):$ImageTag"
    & aws cloudformation deploy `
        --template-file .\cloudformation\batch.yaml `
        --stack-name co3141-batch `
        --parameter-overrides `
            ProjectName=co3141 `
            ImageUri=$imageUri `
            SubnetAId=$($infra.PublicSubnetAId) `
            SubnetBId=$($infra.PublicSubnetBId) `
            BatchSecurityGroupId=$($infra.BatchSecurityGroupId) `
            InstanceProfileArn=$($infra.EcsInstanceProfileArn) `
            TaskExecutionRoleArn=$($infra.EcsTaskExecutionRoleArn) `
            LogGroupName=$($data.WorkloadLogGroupName) `
        --region $Region --profile $Profile
    if ($LASTEXITCODE -ne 0) { throw "Batch stack deployment failed." }
    Write-Host "AWS Batch resources deployed with MinvCpus=0 and DesiredvCpus=0." -ForegroundColor Green
} finally {
    Pop-Location
}
