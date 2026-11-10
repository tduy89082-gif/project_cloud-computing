param(
    [string]$Profile = "co3141",
    [string]$Region = "ap-southeast-1",
    [string]$JobName = "co3141-demo-job"
)
$ErrorActionPreference = "Stop"
$raw = & aws cloudformation describe-stacks --stack-name co3141-batch --region $Region --profile $Profile --output json
if ($LASTEXITCODE -ne 0) { throw "Deploy co3141-batch first by running scripts/deploy-batch.ps1." }
$outputs = ($raw | ConvertFrom-Json).Stacks[0].Outputs
$queue = ($outputs | Where-Object OutputKey -eq "JobQueueArn").OutputValue
$definition = ($outputs | Where-Object OutputKey -eq "JobDefinitionArn").OutputValue
if (-not $queue -or -not $definition) { throw "Batch stack outputs are missing JobQueueArn or JobDefinitionArn." }

$submitRaw = & aws batch submit-job --job-name $JobName --job-queue $queue --job-definition $definition --region $Region --profile $Profile --output json
if ($LASTEXITCODE -ne 0) { throw "AWS Batch submit-job failed." }
$jobId = ($submitRaw | ConvertFrom-Json).jobId
Write-Host "Submitted AWS Batch job: $jobId" -ForegroundColor Cyan

$job = $null
for ($attempt = 0; $attempt -lt 90; $attempt++) {
    Start-Sleep -Seconds 10
    $jobRaw = & aws batch describe-jobs --jobs $jobId --region $Region --profile $Profile --output json
    if ($LASTEXITCODE -ne 0) { throw "Could not read Batch job status." }
    $job = ($jobRaw | ConvertFrom-Json).jobs[0]
    Write-Host "Status: $($job.status)"
    if ($job.status -in @("SUCCEEDED", "FAILED")) { break }
}
if (-not $job -or $job.status -notin @("SUCCEEDED", "FAILED")) {
    throw "Job has not reached a terminal state after 15 minutes. Inspect the job queue and compute environment in AWS Batch." 
}
$job | Select-Object jobId,jobName,status,statusReason,@{Name="ExitCode";Expression={$_.container.exitCode}} | Format-List
if ($job.status -eq "FAILED") { throw "Batch job failed. Read its CloudWatch log stream and statusReason." }
Write-Host "Logs: CloudWatch Logs -> /co3141/co3141/workload -> recent batch streams." -ForegroundColor Green
