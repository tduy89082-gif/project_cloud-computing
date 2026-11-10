$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
Push-Location $repoRoot
try {
    foreach ($command in @("docker", "kind", "kubectl")) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command '$command' was not found. Install Docker Desktop, kind and kubectl first."
        }
    }
    docker info | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not running." }
    kind create cluster --name co3141 --config .\k8s\kind-cluster.yaml
    if ($LASTEXITCODE -ne 0) { throw "Could not create kind cluster. Check whether cluster co3141 already exists." }
    kubectl apply -f .\k8s\scheduler-demo.yaml
    if ($LASTEXITCODE -ne 0) { throw "Could not apply the Kubernetes scheduler demo manifest." }
    kubectl rollout status deployment/co3141-cpu -n co3141 --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw "Deployment did not become ready. Inspect kubectl describe pods -n co3141." }
    Write-Host "Pod placement across kind worker nodes:" -ForegroundColor Green
    kubectl get pods -n co3141 -o wide
    Write-Host "Save the NODE column as evidence, then run scripts/cleanup-kind-demo.ps1." -ForegroundColor Cyan
} finally {
    Pop-Location
}
