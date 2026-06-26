# End-to-end steering demo. Run AFTER `func start` is serving on :7071.
#   pwsh ./demo.ps1
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:7071/api'

function Show($label, $runId) {
    $s = Invoke-RestMethod "$base/runs/$runId"
    Write-Host "`n[$label] status=$($s.status) step=$($s.currentStep)/$($s.maxSteps) instruction='$($s.instruction)'"
    $s.auditLog | ForEach-Object { Write-Host "   - $_" }
}

Write-Host 'Starting run...'
$start = Invoke-RestMethod "$base/runs" -Method Post -ContentType 'application/json' `
    -Headers @{ 'Idempotency-Key' = [guid]::NewGuid().ToString() } `
    -Body '{ "instruction": "summarize the docs", "maxSteps": 10 }'
$run = $start.runId
Write-Host "runId = $run"

Start-Sleep -Seconds 2; Show 'after ~2s running' $run

Write-Host "`nPausing..."
Invoke-RestMethod "$base/runs/$run/steer" -Method Post -ContentType 'application/json' -Body '{ "action": "Pause" }' | Out-Null
Start-Sleep -Seconds 1; Show 'paused' $run

Write-Host "`nRedirecting instruction..."
Invoke-RestMethod "$base/runs/$run/steer" -Method Post -ContentType 'application/json' -Body '{ "action": "Redirect", "newInstruction": "translate the docs instead" }' | Out-Null

Write-Host 'Resuming...'
Invoke-RestMethod "$base/runs/$run/steer" -Method Post -ContentType 'application/json' -Body '{ "action": "Resume" }' | Out-Null
Start-Sleep -Seconds 2; Show 'resumed (new instruction)' $run

Write-Host "`nKilling..."
Invoke-RestMethod "$base/runs/$run/steer" -Method Post -ContentType 'application/json' -Body '{ "action": "Kill" }' | Out-Null
Start-Sleep -Seconds 1; Show 'killed' $run
