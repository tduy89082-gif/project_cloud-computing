param(
    [string]$Profile = "co3141",
    [string]$Region = "ap-southeast-1",
    [string]$Repository = "co3141-workload",
    [string]$Tag = "v1"
)
$ErrorActionPreference = "Stop"

$accountId = aws sts get-caller-identity --profile $Profile --query Account --output text
if ($LASTEXITCODE -ne 0) { throw "AWS CLI identity check failed. Configure the profile first." }
$repoUri = "$accountId.dkr.ecr.$Region.amazonaws.com/$Repository"

aws ecr get-login-password --region $Region --profile $Profile | docker login --username AWS --password-stdin "$accountId.dkr.ecr.$Region.amazonaws.com"
if ($LASTEXITCODE -ne 0) { throw "Docker login to ECR failed." }

Push-Location (Join-Path $PSScriptRoot "..\workload")
try {
    docker build -t "$Repository`:$Tag" .
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed." }
    docker tag "$Repository`:$Tag" "$repoUri`:$Tag"
    docker push "$repoUri`:$Tag"
    if ($LASTEXITCODE -ne 0) { throw "Docker push failed." }
    Write-Host "Pushed image: $repoUri`:$Tag" -ForegroundColor Green
} finally {
    Pop-Location
}
