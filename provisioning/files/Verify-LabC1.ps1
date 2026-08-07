#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$ok = $true

# Veeam Backup & Replication 11+ ships a PowerShell module. The old VeeamPSSnapIn snap-in
# is gone, and Add-PSSnapin itself does not exist in PowerShell 7 (snap-ins were dropped in
# PowerShell Core), so loading it that way fails on both counts.
$veeamLoaded = $false
try {
    if (-not (Get-Module -Name Veeam.Backup.PowerShell)) {
        # -DisableNameChecking suppresses the module's "unapproved verbs" warning, which is
        # cosmetic but reads like a failure to a learner running the verification.
        Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction Stop
    }
    $veeamLoaded = $true
} catch {
    Write-Host "[FAIL] Cannot load the Veeam PowerShell module: $_"
    $ok = $false
}

# 1 - LIN01 must be Running on SRV02 (post-failover validation)
# LIN01 sits on an internal-only virtual switch and has no routable production IP, so it
# cannot be pinged from this host. Query the VM state on the DR hypervisor instead, and
# call ToString() remotely so the VMState enum survives deserialization as a name.
try {
    $state = Invoke-Command -ComputerName SRV02 { (Get-VM -Name LIN01).State.ToString() }
    if ($state -eq 'Running') {
        Write-Host '[PASS] LIN01 is Running on SRV02 (post-failover)'
    } else {
        Write-Host "[FAIL] LIN01 state on SRV02: $state"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot check LIN01 on SRV02: $_"
    $ok = $false
}

# 2 - Critical.txt must have been recovered onto this host (BCKUP1) via guest file restore.
$criticalPaths = @(
    "$env:USERPROFILE\Desktop\Critical.txt",
    'C:\Users\domainuser\Desktop\Critical.txt',
    'C:\Critical.txt'
)
$found = $criticalPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $found) {
    Write-Host "[FAIL] Critical.txt not found on BCKUP1 - looked in: $($criticalPaths -join ', ')"
    $ok = $false
} else {
    try {
        $content = Get-Content $found -ErrorAction Stop
        if ($content -match 'CADMUS CR09') {
            Write-Host "[PASS] Critical.txt recovered to $found with expected content"
        } else {
            Write-Host "[FAIL] Critical.txt found at $found but its content is unexpected"
            $ok = $false
        }
    } catch {
        Write-Host "[FAIL] Cannot read $($found): $_"
        $ok = $false
    }
}

# 3 - A successful restore of LIN01 to the alternate location (LIN01-Test) must exist
if ($veeamLoaded) {
    $connected = $false
    try {
        Connect-VBRServer -Server localhost -ErrorAction Stop
        $connected = $true

        # The session is named after the SOURCE VM (LIN01), not the new name the learner
        # typed on the wizard's Name page - so matching on 'LIN01-Test' finds nothing even
        # after a successful drill. Match the source VM instead. Guest file restore sessions
        # are named FLR_[dc01.drlab.local] and do not collide with this filter.
        $session = Get-VBRRestoreSession |
            Where-Object { $_.Name -like '*LIN01*' } |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1

        if (-not $session) {
            Write-Host '[FAIL] No LIN01 restore session found - was the alternate-location restore run?'
            $ok = $false
        } elseif ($session.Result -eq 'Success') {
            Write-Host "[PASS] LIN01 alternate-location restore completed successfully ($($session.Name))"
        } else {
            Write-Host "[FAIL] Latest LIN01 restore session result: $($session.Result)"
            $ok = $false
        }
    } catch {
        Write-Host "[FAIL] Veeam restore session check failed: $_"
        $ok = $false
    } finally {
        if ($connected) {
            Disconnect-VBRServer -ErrorAction SilentlyContinue
        }
    }
}

if ($ok) {
    Write-Host ''
    Write-Host 'Passkey: recovery-validated'
}
