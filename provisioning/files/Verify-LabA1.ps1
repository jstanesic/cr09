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

# 1 - LIN01 must be Running on SRV01 (restored from backup)
# Call ToString() on the remote side: PowerShell remoting deserializes the VMState enum into
# a plain value on return, so the local comparison would see 2 (VMState.Running) rather than
# the name 'Running' and always fail.
try {
    $state = Invoke-Command -ComputerName SRV01 { (Get-VM -Name LIN01).State.ToString() }
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

# 2 - Veeam job must have completed successfully
if ($veeamLoaded) {
    $connected = $false
    try {
        Connect-VBRServer -Server localhost -ErrorAction Stop
        $connected = $true

        $jobName = 'Backup LIN01 - Primary'

        $job = Get-VBRJob -Name $jobName -ErrorAction SilentlyContinue
        if (-not $job) {
            throw "Backup job '$jobName' not found"
        }

        # Query the session list rather than a job object method - method names on the job
        # object vary between VBR releases, session cmdlets do not.
        $session = Get-VBRBackupSession |
            Where-Object { $_.JobName -eq $jobName } |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1

        if (-not $session) {
            throw "Job '$jobName' has never run"
        }

        if ($session.Result -eq 'Success') {
            Write-Host '[PASS] Backup job completed successfully'
        } else {
            Write-Host "[FAIL] Backup job result: $($session.Result)"
            $ok = $false
        }
    } catch {
        Write-Host "[FAIL] Veeam check failed: $_"
        $ok = $false
    } finally {
        if ($connected) {
            Disconnect-VBRServer -ErrorAction SilentlyContinue
        }
    }
}

if ($ok) {
    Write-Host ''
    Write-Host 'Passkey: snapshot-vs-backup-verified'
}
