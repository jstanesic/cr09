#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

$ok = $true

# 1 — NSRV03 must be Running on SRV02 (planned failover completed)
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

# 2 — DC01 backup (.vbk) must exist on BCKUP2
try {
    $vbk = Invoke-Command -ComputerName BCKUP2 {
        Get-ChildItem C:\VeeamBackups -Recurse -Filter *.vbk -ErrorAction SilentlyContinue
    }
    if ($vbk) {
        Write-Host '[PASS] DC01 backup (.vbk) found on BCKUP2'
    } else {
        Write-Host '[FAIL] No .vbk found in C:\VeeamBackups on BCKUP2'
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot check BCKUP2: $_"
    $ok = $false
}

if ($ok) {
    Write-Host ''
    Write-Host 'Passkey: replica-failover-verified'
}
