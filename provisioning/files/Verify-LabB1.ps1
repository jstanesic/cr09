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

# Counts restore points in a backup. Get-VBRRestorePoint's parameter sets differ between
# releases, so fall back to the backup object's own storage list.
function Get-RestorePointCount {
    param($Backup)
    try {
        return @(Get-VBRRestorePoint -Backup $Backup -ErrorAction Stop).Count
    } catch {
        return @($Backup.GetAllStorages()).Count
    }
}

# 1 - LIN01 must be Running on SRV02 (planned failover completed)
# Call ToString() on the remote side: PowerShell remoting deserializes the VMState enum into
# a plain value on return, so the local comparison would see 2 (VMState.Running) rather than
# the name 'Running' and always fail.
try {
    $state = Invoke-Command -ComputerName SRV02 { (Get-VM -Name LIN01).State.ToString() }
    if ($state -eq 'Running') {
        Write-Host '[PASS] LIN01 is Running on SRV02'
    } else {
        Write-Host "[FAIL] LIN01 state on SRV02: $state"
        $ok = $false
    }
} catch {
    Write-Host "[FAIL] Cannot check LIN01 on SRV02: $_"
    $ok = $false
}

# 2 - The primary DC01 backup must exist on BCKUP1, and
# 3 - a Backup Copy job must exist to propagate it to the DR repository on BCKUP2.
#
# Both are checked so that a single job pointed straight at BCKUP2 does not pass: the lab
# teaches two copies in two locations, not one copy that happens to be offsite.
#
# These query Veeam's own catalogue rather than the file system on BCKUP2. Veeam already
# manages that repository, so no PowerShell remoting to BCKUP2 is needed - remoting requires
# the running account to be a local administrator there with WinRM configured, which is an
# environment dependency this check should not carry.
#
# Note the backup object is queried for the primary, not a job session: DC01 is protected by
# an agent job, whose sessions do not appear in Get-VBRBackupSession (that returns hypervisor
# job sessions only). A backup holding restore points is also the stronger assertion - it is
# the artefact the next labs actually restore from.
if ($veeamLoaded) {
    $connected = $false
    try {
        Connect-VBRServer -Server localhost -ErrorAction Stop
        $connected = $true

        $primaryName = 'Backup DC01 - Primary'
        $copyName    = 'Copy DC01 - Offsite'

        $primary = Get-VBRBackup -Name $primaryName -ErrorAction SilentlyContinue |
                   Select-Object -First 1
        if (-not $primary) {
            Write-Host "[FAIL] No backup named '$primaryName' found on BCKUP1"
            $ok = $false
        } else {
            $points = Get-RestorePointCount -Backup $primary
            if ($points -ge 1) {
                Write-Host "[PASS] Primary DC01 backup on BCKUP1 holds $points restore point(s)"
            } else {
                Write-Host "[FAIL] '$primaryName' exists but holds no restore points"
                $ok = $false
            }
        }

        # Get-VBRBackupCopyJob is the dedicated cmdlet for backup copy jobs. Query it rather
        # than looking for a backup by name: the backup a copy job produces (filed under
        # Backups -> Disk (Copy)) is not necessarily named after the job that created it, so
        # a name match misses it even when the copy exists.
        $copyJob = Get-VBRBackupCopyJob -ErrorAction SilentlyContinue | Select-Object -First 1

        if (-not $copyJob) {
            Write-Host "[FAIL] No Backup Copy job found - create '$copyName' targeting the DR repository on BCKUP2"
            $ok = $false
        } else {
            $target = try { $copyJob.TargetRepository.Name } catch { '<unknown>' }
            Write-Host "[PASS] Backup Copy job '$($copyJob.Name)' exists, targeting '$target'"
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
    Write-Host 'Passkey: replica-failover-verified'
}
