#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ok = $true

# 1 — LIN01 web server must respond with "It works!"
try {
    $resp = Invoke-WebRequest -Uri 'http://10.9.10.21' -UseBasicParsing -TimeoutSec 10
    if ($resp.Content -like '*It works!*') {
        Write-Host '[PASS] LIN01 web server is up and serving "It works!"'
    } else {
        Write-Host '[FAIL] LIN01 responded but content unexpected'
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot reach LIN01 at 10.9.10.21: $_"
    $ok = $false
}

# 2 — LIN01 VM must exist and be Running on SRV01 (only present after Import Backup + restore)
try {
    $state = Invoke-Command -ComputerName SRV01 {
        $vm = Get-VM -Name LIN01 -ErrorAction SilentlyContinue
        if ($vm) { $vm.State } else { 'NotFound' }
    }
    if ($state -eq 'Running') {
        Write-Host '[PASS] LIN01 is Running on SRV01'
    } else {
        Write-Host "[FAIL] LIN01 state on SRV01: $state"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot check LIN01 on SRV01: $_"
    $ok = $false
}

if ($ok) {
    Write-Host ''
    Write-Host 'Passkey: recovery-validated'
}
