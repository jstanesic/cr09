#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

$ok = $true

# 1 — NSRV03 must be reachable and healthy on SRV02 (post-failover validation)
try {
    $resp = Test-Connection -ComputerName 10.9.10.20 -Count 4 -ErrorAction Stop
    if ($resp) {
        Write-Host '[PASS] NSRV03 is reachable at 10.9.10.20 (post-failover)'
    } else {
        Write-Host '[FAIL] NSRV03 did not respond at 10.9.10.20'
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot reach NSRV03 at 10.9.10.20: $_"
    $ok = $false
}

# 2 — Critical.txt must have been restored to DC01 via granular file restore
try {
    $content = Invoke-Command -ComputerName DC01 {
        Get-Content 'C:\Users\Administrator\Documents\Critical.txt' -ErrorAction Stop
    }
    if ($content -match 'CADMUS CR09') {
        Write-Host '[PASS] Critical.txt restored to DC01 with expected content'
    } else {
        Write-Host '[FAIL] Critical.txt present but content unexpected'
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot read Critical.txt on DC01: $_"
    $ok = $false
}

# 3 — A successful restore of NSRV03 to the alternate location (NSRV03-Test) must exist
try {
    $session = Get-VBRRestoreSession |
        Where-Object { $_.Name -like '*NSRV03-Test*' } |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1
    if ($session -and $session.Result -eq 'Success') {
        Write-Host '[PASS] NSRV03-Test alternate-location restore completed successfully'
    } else {
        Write-Host "[FAIL] No successful NSRV03-Test restore session found"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Veeam restore session check failed: $_"
    $ok = $false
}

if ($ok) {
    Write-Host ''
    Write-Host 'Passkey: recovery-validated'
}
