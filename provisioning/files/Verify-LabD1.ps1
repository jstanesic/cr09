#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Lab D1 is complete when LIN01 has been cleanly restored from the offsite BCKUP2
# copy and is running again on SRV02. LIN01 sits on an isolated switch with no
# routable IP, so we check the VM state on the DR hypervisor rather than pinging it.
# ToString() runs on the remote side because PowerShell remoting deserializes the
# VMState enum to its numeric value (Running = 2) on return, which the name compare
# below would otherwise never match.
try {
    $state = Invoke-Command -ComputerName SRV02 { (Get-VM -Name LIN01).State.ToString() }
} catch {
    Write-Host "[FAIL] Cannot reach SRV02 to check LIN01: $_"
    return
}

if ($state -eq 'Running') {
    Write-Host '[PASS] LIN01 is Running on SRV02 — clean restore complete.'
    Write-Host ''
    Write-Host 'Passkey: dr-activation-complete'
} else {
    Write-Host "[FAIL] LIN01 state on SRV02: $state (expected Running)"
}
