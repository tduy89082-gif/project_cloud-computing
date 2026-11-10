param([Parameter(Mandatory=$true)][string]$BaseUrl)
$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd('/')
Write-Host "Health check: $BaseUrl/health"
Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get | ConvertTo-Json -Depth 5
Write-Host "CPU workload: $BaseUrl/work?seconds=3"
Invoke-RestMethod -Uri "$BaseUrl/work?seconds=3" -Method Get | ConvertTo-Json -Depth 5
