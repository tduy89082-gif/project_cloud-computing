param(
    [Parameter(Mandatory=$true)][string]$BaseUrl,
    [int]$Workers = 8,
    [int]$RequestsPerWorker = 3,
    [int]$Seconds = 5
)
$ErrorActionPreference = "Stop"
if ($Workers -lt 1 -or $Workers -gt 20) { throw "Workers must be between 1 and 20." }
if ($RequestsPerWorker -lt 1 -or $RequestsPerWorker -gt 20) { throw "RequestsPerWorker must be between 1 and 20." }
if ($Seconds -lt 1 -or $Seconds -gt 30) { throw "Seconds must be between 1 and 30." }
$BaseUrl = $BaseUrl.TrimEnd('/')

Write-Host "Starting $Workers background workers x $RequestsPerWorker request(s), $Seconds seconds each." -ForegroundColor Cyan
$jobs = @()
for ($i = 1; $i -le $Workers; $i++) {
    $jobs += Start-Job -ArgumentList $BaseUrl,$RequestsPerWorker,$Seconds,$i -ScriptBlock {
        param($url,$count,$seconds,$workerId)
        $results = @()
        for ($j = 1; $j -le $count; $j++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $null = Invoke-RestMethod -Uri "$url/work?seconds=$seconds" -TimeoutSec ($seconds + 30)
                $sw.Stop()
                $results += [pscustomobject]@{ Worker=$workerId; Request=$j; Status='OK'; ElapsedSeconds=[math]::Round($sw.Elapsed.TotalSeconds,2) }
            } catch {
                $sw.Stop()
                $results += [pscustomobject]@{ Worker=$workerId; Request=$j; Status='ERROR'; ElapsedSeconds=[math]::Round($sw.Elapsed.TotalSeconds,2); Error=$_.Exception.Message }
            }
        }
        $results
    }
}
Wait-Job -Job $jobs | Out-Null
$results = @($jobs | Receive-Job)
$jobs | Remove-Job
$results | Format-Table -AutoSize
$ok = @($results | Where-Object Status -eq 'OK').Count
$errors = @($results | Where-Object Status -ne 'OK').Count
Write-Host "Completed: $ok successful, $errors failed. Check ECS service CPU and desired/running task metrics in CloudWatch." -ForegroundColor Green
