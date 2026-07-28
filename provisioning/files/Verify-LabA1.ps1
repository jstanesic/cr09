#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

$ok = $true

# 1 — LIN01 must be Running on SRV01 (restored from backup)
try {
    $state = Invoke-Command -ComputerName SRV01 { (Get-VM -Name LIN01).State }
    if ($state -eq 'Running') {
        Write-Host '[PASS] LIN01 is Running on SRV01'
    } else {
        Write-Host "[FAIL] LIN01 state: $state"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot check LIN01 on SRV01: $_"
    $ok = $false
}

# 2 — Veeam job must have completed successfully
try {
    $job     = Get-VBRJob -Name 'Backup LIN01 - Primary'
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
