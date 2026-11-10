$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {
    kind delete cluster --name co3141
    if ($LASTEXITCODE -ne 0) { throw "kind cluster cleanup failed. Check 'kind get clusters'." }
    Write-Host "Local kind cluster removed." -ForegroundColor Green
} finally {
    Pop-Location
}
