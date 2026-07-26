# Runbook — Build `NSRV03.vbk` (smallest possible) for the A1 restore

Lab **A1** starts by *importing* a pre-existing Veeam backup of the production
application server **NSRV03** (`On BCKUP1, Import Backup -> Select NSRV03.vbk
(from C:\Installs\Backups)`), then restoring it onto SRV01. No lab produces
this file, so it must be built once and **baked into the Veeam-preinstalled
base image** at the path in `nsrv03_vbk_path` (see
`provisioning/group_vars/veeam-servers.yml`).

Target outcome: a single `NSRV03.vbk` (~0.5–1 GB) that restores onto SRV01,
runs the `legacy-app` systemd service, and answers on **10.9.10.20**.

## Identity to bake in

| Setting | Value | Source |
|---|---|---|
| Distribution | **Debian 12** (`debian-12-x86_64`), minimal / no GUI | matches `lab_env_description.md`; keeps `systemctl`/`ls` lab steps valid |
| Hostname | **NSRV03** | lab_env_description.md |
| DNS domain / search suffix | **drlab.local** → FQDN `nsrv03.drlab.local` | matches the lab AD domain (`ad_domain_name`); **NSRV03 is NOT domain-joined** |
| IP / prefix | **10.9.10.20/24** | topology `net_mappings` (historical — see note below) |
| Gateway | **10.9.10.1** (r-prod) | topology |
| DNS server | **8.8.8.8** (public — not the DC) | lab_env_description.md |
| Neighbour to avoid | none — LIN01 has been removed from the course | — |
| Local account | `localuser` / `Password123!`, sudo-enabled | matches every other Linux node in the course |

> **Why Debian 12 / Gen 1:** Debian 12 is the smallest platform image that
> keeps the `systemctl`/`ls /data` verification working. A **Generation 1**
> Hyper-V VM avoids Secure Boot setup, has a single MBR partition (no EFI
> partition to zero), and restores without firmware mismatch. Gen 2 is fine
> too — just `Set-VMFirmware -EnableSecureBoot Off` and keep the SRV01 restore
> target Gen 2 as well.

---

## Phase 1 — Create the source VM (Hyper-V)

```powershell
New-VM -Name NSRV03 -Generation 1 -MemoryStartupBytes 1GB `
  -NewVHDPath 'C:\Hyper-V\NSRV03\NSRV03.vhdx' -NewVHDSizeBytes 8GB `
  -SwitchName 'Production-Switch'
Set-VM -Name NSRV03 -ProcessorCount 1 -DynamicMemory `
  -MemoryMinimumBytes 512MB -MemoryMaximumBytes 1GB
```
Attach the **Debian 12 netinst** ISO and boot.

## Phase 2 — Minimal Debian install

- Choose **Install** (text), not graphical/desktop.
- Partitioning: **Guided – entire disk → all files in one partition**; swap ≤ 512 MB or none.
- **tasksel: deselect everything** except *standard system utilities* (SSH optional). Biggest size lever.
- Hostname `NSRV03`, domain `drlab.local`. Finish, reboot, remove ISO.

## Phase 3 — Network identity

```bash
ip -br link    # confirm interface name (Hyper-V Gen1 is usually eth0)

sudo tee /etc/network/interfaces.d/eth0 >/dev/null <<'EOF'
auto eth0
iface eth0 inet static
    address 10.9.10.20/24
    gateway 10.9.10.1
    dns-nameservers 8.8.8.8
    dns-search drlab.local
EOF

# hostname / FQDN (not AD-joined — just a consistent suffix)
echo 'NSRV03' | sudo tee /etc/hostname
sudo sed -i '/127.0.1.1/d' /etc/hosts
echo '127.0.1.1   NSRV03.drlab.local   NSRV03' | sudo tee -a /etc/hosts
echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf

sudo systemctl restart networking
hostname -f && ip -4 addr show eth0    # expect nsrv03.drlab.local / 10.9.10.20
```

## Phase 4 — Local trainee account, app dataset, service and D1 script

```bash
# Trainee account (matches every other Linux node in the course)
sudo useradd -m -s /bin/bash localuser
echo 'localuser:Password123!' | sudo chpasswd
sudo usermod -aG sudo localuser

# /data application dataset
sudo mkdir -p /data
for f in invoices.dat customers.dat ledger.dat; do
  echo "CADMUS CR09 production data — $f" | sudo tee "/data/$f" >/dev/null
done
sudo chown -R root:root /data && sudo chmod 0755 /data

# legacy-app systemd unit (status checked in B1/C1)
sudo tee /etc/systemd/system/legacy-app.service >/dev/null <<'EOF'
[Unit]
Description=CADMUS CR09 Legacy Application Service
After=network-online.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'while true; do sleep 30; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now legacy-app
systemctl status legacy-app    # confirm active (running)

# Ransomware-simulation script used by the D1 capstone
sudo mkdir -p /opt/scripts
sudo tee /opt/scripts/simulate_ransomware.sh >/dev/null <<'EOF'
#!/bin/sh
# CADMUS CR09 — Lab D1 disaster-recovery drill.
# SIMULATION ONLY: renames files under /data to *.crypted and posts a
# ransom message as the message-of-the-day. It does NOT encrypt data
# and is fully reversible by restoring /data from backup.
set -e
for f in /data/*; do
  case "$f" in
    *.crypted) ;;                       # already "encrypted"
    *) [ -f "$f" ] && mv "$f" "$f.crypted" ;;
  esac
done
cat > /etc/motd <<'BANNER'
============================================================
  !!!  YOUR FILES HAVE BEEN LOCKED  !!!
  All data in /data has been encrypted (.crypted).
  (SIMULATED — CADMUS CR09 training exercise)
============================================================
BANNER
echo "Simulation complete: /data locked, MOTD replaced."
EOF
sudo chmod 0750 /opt/scripts/simulate_ransomware.sh
sudo chown root:root /opt/scripts/simulate_ransomware.sh
```

## Phase 5 — Shrink the footprint before capture

```bash
sudo apt-get purge -y tasksel
sudo apt-get autoremove --purge -y
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /var/cache/*
sudo find /var/log -type f -exec truncate -s 0 {} \;

# disable swap so swap blocks don't bloat the backup
sudo swapoff -a   # and comment any swap line in /etc/fstab

# zero free space so Veeam compresses empty blocks away, then power off
sudo dd if=/dev/zero of=/zero bs=1M 2>/dev/null; sync; sudo rm -f /zero
sudo fstrim -av 2>/dev/null || true
sudo shutdown -h now
```
Optional on the host (VM off): `Optimize-VHD -Path 'C:\Hyper-V\NSRV03\NSRV03.vhdx' -Mode Full`.

## Phase 6 — Capture with Veeam (smallest-file settings)

On **BCKUP1** → Veeam console → add the Hyper-V host → new **Backup Job** for `NSRV03`.
In **Storage → Advanced**:

- **Compression level: Extreme**
- **Storage optimization: WAN target** (smallest blocks → best compression on a tiny VM)
- **Exclude deleted file blocks** (BitLooker) — keep on
- **Exclude swap file blocks** — keep on

Run once as an **Active Full** → produces `*.vbk` (+ `*.vbm`). Expect ~0.5–1 GB.

## Phase 7 — Stage the artifact for A1

```powershell
Copy-Item '<repo>\...\NSRV03*.vbk' 'C:\Installs\Backups\NSRV03.vbk'
Copy-Item '<repo>\...\NSRV03*.vbm' 'C:\Installs\Backups\'   # helps a clean Import
```
**Bake** `C:\Installs\Backups\NSRV03.vbk` into the Veeam-preinstalled base image.

Smoke-test: in Veeam, **Import Backup → `C:\Installs\Backups\NSRV03.vbk`**, restore to
SRV01, boot, confirm `systemctl status legacy-app` is active and `/data` holds the
three seed files.

> Keep the `.vbm` alongside the `.vbk`. Veeam can rebuild metadata from a lone
> `.vbk`, but shipping the matching `.vbm` makes the A1 *Import Backup* clean.
> Do **not** change the `C:\Installs\Backups` path — `lab_a1.md` references it verbatim.
