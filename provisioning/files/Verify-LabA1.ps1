#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

$ok = $true

# 1 — NSRV03 must be Running on SRV01 (restored from backup)
try {
    $state = Invoke-Command -ComputerName SRV01 { (Get-VM -Name NSRV03).State }
    if ($state -eq 'Running') {
        Write-Host '[PASS] NSRV03 is Running on SRV01'
    } else {
        Write-Host "[FAIL] NSRV03 state: $state"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot check NSRV03 on SRV01: $_"
    $ok = $false
}

# 2 — Veeam job must have completed successfully
try {
    $job     = Get-VBRJob -Name 'Backup NSRV03 - Primary'
    $session = $job.GetLastBackupSession()
    if ($session.Result -eq 'Success') {
        Write-Host '[PASS] Backup job completed successfully'
    } else {
        Write-Host "[FAIL] Backup job result: $($session.Result)"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Veeam check failed: $_"
    $ok = $false
}

if ($ok) {
    Write-Host ''
    Write-Host 'Passkey: snapshot-vs-backup-verified'
}
