#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

$ok = $true

# 1 — NSRV03 must be Running on SRV02 (restored from BCKUP2 after ransomware)
try {
    $state = Invoke-Command -ComputerName SRV02 { (Get-VM -Name NSRV03).State }
    if ($state -eq 'Running') {
        Write-Host '[PASS] NSRV03 is Running on SRV02'
    } else {
        Write-Host "[FAIL] NSRV03 state on SRV02: $state"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot check NSRV03 on SRV02: $_"
    $ok = $false
}

# 2 — A completed Veeam restore session for NSRV03 must exist on this host
try {
    $session = Get-VBRRestoreSession |
               Where-Object { $_.Name -like '*NSRV03*' } |
               Sort-Object EndTime |
               Select-Object -Last 1
    if ($session -and $session.Result -eq 'Success') {
        Write-Host '[PASS] Veeam restore for NSRV03 completed successfully'
    } else {
        $result = if ($session) { $session.Result } else { 'no session found' }
        Write-Host "[FAIL] Restore session: $result"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Veeam restore check failed: $_"
    $ok = $false
}

if ($ok) {
    Write-Host ''
    Write-Host 'Passkey: dr-activation-complete'
}
