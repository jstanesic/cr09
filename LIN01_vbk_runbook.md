# Runbook — Build `LIN01.vbk` (smallest possible) for the C1 restore

Lab **C1** starts by *importing* a pre-existing Veeam backup of the legacy web
server **LIN01** (`On BCKUP1, Import Backup -> Select LIN01.vbk (from
C:\Installs\Backups)`). No lab produces this file, so it must be built once and
**baked into the Veeam-preinstalled base image** at the path in
`lin01_vbk_path` (see `provisioning/group_vars/veeam-servers.yml`).

Target outcome: a single `LIN01.vbk` (~0.5–1 GB) that restores onto SRV01 and
serves "It works!" on **http://10.9.10.21**.

## Identity to bake in

| Setting | Value | Source |
|---|---|---|
| Distribution | **Debian 12** (`debian-12-x86_64`), minimal / no GUI | platform-provided image; keeps `apache2` + `systemctl` lab steps valid |
| Hostname | **LIN01** | lab_env_description.md |
| DNS domain / search suffix | **drlab.local** → FQDN `lin01.drlab.local` | matches the lab AD domain (`ad_domain_name`); **LIN01 is NOT domain-joined** |
| IP / prefix | **10.9.10.21/24** | topology `net_mappings` |
| Gateway | **10.9.10.1** (r-prod) | topology |
| DNS server | **8.8.8.8** (public — not the DC) | lab_env_description.md |
| Neighbour to avoid | NSRV03 = 10.9.10.20 | topology |

> **Why Debian 12 / Gen 1:** Debian 12 is the smallest platform image that keeps
> the `apache2`/`systemctl`/`curl "It works!"` verification working (Alpine/RHEL
> would break those). A **Generation 1** Hyper-V VM avoids Secure Boot setup, has
> a single MBR partition (no EFI partition to zero), and restores without firmware
> mismatch. Gen 2 is fine too — just `Set-VMFirmware -EnableSecureBoot Off` and
> keep the SRV01 restore target Gen 2 as well.

---

## Phase 1 — Create the source VM (Hyper-V)

```powershell
New-VM -Name LIN01 -Generation 1 -MemoryStartupBytes 1GB `
  -NewVHDPath 'C:\Hyper-V\LIN01\LIN01.vhdx' -NewVHDSizeBytes 8GB `
  -SwitchName 'Production-Switch'
Set-VM -Name LIN01 -ProcessorCount 1 -DynamicMemory `
  -MemoryMinimumBytes 512MB -MemoryMaximumBytes 1GB
```
Attach the **Debian 12 netinst** ISO and boot.

## Phase 2 — Minimal Debian install

- Choose **Install** (text), not graphical/desktop.
- Partitioning: **Guided – entire disk → all files in one partition**; swap ≤ 512 MB or none.
- **tasksel: deselect everything** except *standard system utilities* (SSH optional). Biggest size lever.
- Hostname `LIN01`, domain `drlab.local`. Finish, reboot, remove ISO.

## Phase 3 — Network identity

```bash
ip -br link    # confirm interface name (Hyper-V Gen1 is usually eth0)

sudo tee /etc/network/interfaces.d/eth0 >/dev/null <<'EOF'
auto eth0
iface eth0 inet static
    address 10.9.10.21/24
    gateway 10.9.10.1
    dns-nameservers 8.8.8.8
    dns-search drlab.local
EOF

# hostname / FQDN (not AD-joined — just a consistent suffix)
echo 'LIN01' | sudo tee /etc/hostname
sudo sed -i '/127.0.1.1/d' /etc/hosts
echo '127.0.1.1   LIN01.drlab.local   LIN01' | sudo tee -a /etc/hosts
echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf

sudo systemctl restart networking
hostname -f && ip -4 addr show eth0    # expect lin01.drlab.local / 10.9.10.21
```

## Phase 4 — Apache + verification page

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends -y apache2
echo '<html><body><h1>It works!</h1></body></html>' | sudo tee /var/www/html/index.html
sudo systemctl enable --now apache2
systemctl status apache2 && curl -s localhost      # confirm "It works!"
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
Optional on the host (VM off): `Optimize-VHD -Path 'C:\Hyper-V\LIN01\LIN01.vhdx' -Mode Full`.

## Phase 6 — Capture with Veeam (smallest-file settings)

On **BCKUP1** → Veeam console → add the Hyper-V host → new **Backup Job** for `LIN01`.
In **Storage → Advanced**:

- **Compression level: Extreme**
- **Storage optimization: WAN target** (smallest blocks → best compression on a tiny VM)
- **Exclude deleted file blocks** (BitLooker) — keep on
- **Exclude swap file blocks** — keep on

Run once as an **Active Full** → produces `*.vbk` (+ `*.vbm`). Expect ~0.5–1 GB.

## Phase 7 — Stage the artifact for C1

```powershell
Copy-Item '<repo>\...\LIN01*.vbk' 'C:\Installs\Backups\LIN01.vbk'
Copy-Item '<repo>\...\LIN01*.vbm' 'C:\Installs\Backups\'   # helps a clean Import
```
**Bake** `C:\Installs\Backups\LIN01.vbk` into the Veeam-preinstalled base image.

Smoke-test: in Veeam, **Import Backup → `C:\Installs\Backups\LIN01.vbk`**, restore,
confirm http://10.9.10.21 returns "It works!".

> Keep the `.vbm` alongside the `.vbk`. Veeam can rebuild metadata from a lone
> `.vbk`, but shipping the matching `.vbm` makes the C1 *Import Backup* clean.
> Do **not** change the `C:\Installs\Backups` path — `lab_c1.md` references it verbatim.
