# Omarchy Network & NAS Integration Guide

## Overview

This guide is the end-to-end configuration and troubleshooting reference for keeping your Omarchy (Arch Linux) workstation connected to your Synology NAS via SMB/CIFS.

Single source of truth:

- The share list and NAS host/IP are defined in your local config file (`nas_config.local.sh`).
- This document should describe behavior and verification, not become a second place where the share list drifts.

---

## 1. NAS Share Provisioning (`setup_nas_mounts.sh`)

### Responsibilities

- Installs `nfs-common` and `cifs-utils`.
- Installs `cifs-utils` (Arch).
- Prompts for NAS credentials and stores them at `/etc/samba/credentials/omarchy-nas.creds` (root-owned, `0600`).
- Builds the mount directory layout under `/mnt/nas/` (or `$MOUNT_ROOT`) for every share defined in the script.
- Rewrites `/etc/fstab` with hardened CIFS entries (automount + network-online dependencies).
- Enables `NetworkManager-wait-online.service` when available.
- Mounts each share once for immediate verification (automount keeps things resilient afterward).

Portability note:

- The script installs `cifs-utils` using whatever package manager it detects (`pacman`, `apt`, `dnf`, `zypper`).
- It manages `/etc/fstab` using a clearly marked block so you can run it repeatedly across machines without drift.

Configuration note (consistency across machines):

- Copy `networking/nas_config.example.sh` to `networking/nas_config.local.sh` and edit it.
- `networking/nas_config.local.sh` is gitignored so your network details stay private.
- You can also override by pointing `CONFIG_FILE` at another config file.

### Default CIFS entries appended to `/etc/fstab`

The script writes one line per share. Use the preview command to see the exact lines for *your* environment (including computed `uid`/`gid`):

```bash
./networking/setup_nas_mounts.sh --print-fstab
```

### Options Rationale

- `vers=3.0`: SMB3 for better throughput and security.
- `vers=3.1.1`: Prefer modern SMB3 negotiation.
- `seal`: Enables encryption when negotiated.
- `uid`/`gid`: Files appear owned by the invoking user (Omarchy workstation user).
- `file_mode`/`dir_mode`: Defaults that allow write access to your user and group.
- `nosuid,nodev`: Hardened defaults for network shares.
- `_netdev`: Waits for network before attempting mounts.
- `nofail`: Prevents boot failures if the NAS is offline.
- `noauto`: Defers mounting until the first access so boot is never blocked.
- `x-systemd.automount`: Creates a mount-on-demand unit for each share.
- `x-systemd.requires=network-online.target` / `x-systemd.after=network-online.target`: tie the automount to NetworkManager's link readiness.
- `x-systemd.idle-timeout=600`: Allows systemd to unmount idle shares.

### Re-running the Script

The script manages `/etc/fstab` using a marked block so it is safe to re-run as many times as needed:

```bash
./networking/setup_nas_mounts.sh
```

### Auditing the “single source of truth”

To view the active share list and config without changing the system:

```bash
./networking/setup_nas_mounts.sh --list
```

This output reflects the merged config order:

1. environment variables
2. `networking/nas_config.local.sh` (if present)
3. `CONFIG_FILE` (if provided)

To print the `/etc/fstab` lines the script would write (without writing them):

```bash
./networking/setup_nas_mounts.sh --print-fstab
```

### Health check (no changes)

```bash
./networking/setup_nas_mounts.sh --doctor
```

---

## 2. Network Monitoring (`network-monitor.sh`)

Optional: This workspace does not currently ship `network-monitor.sh`. If you want it added here as an Omarchy-maintained tool, say so and we can port it cleanly.

### Purpose

- Records interface, gateway, DNS, and latency changes every 30 seconds.
- Logs to `~/network-monitor.log` and manages its own PID file (`~/network-monitor.pid`).
- Detects and records interface flips or ping failures for auditing.

### Usage

```bash
./networking/network-monitor.sh start    # run in background
./networking/network-monitor.sh status   # show status and last logs
./networking/network-monitor.sh log      # tail recent entries
./networking/network-monitor.sh stop     # terminate monitoring
```

This script is useful for correlating network drops with NAS access issues, especially after OS updates.

---

## 3. NAS Health Checker (`nas_heartbeat.sh`)

Optional: This workspace does not currently ship `nas_heartbeat.sh`. If you want it added here as an Omarchy-maintained tool, say so and we can port it cleanly.

### Highlights

- Pings the NAS host/IP from your local config.
- Validates SMB service availability and existing mounts.
- Attempts remounts if a share goes missing.
- Monitors disk space thresholds (warning at 90%, critical at 95%).
- Sends email alerts (requires `mailutils`).
- Logs to `/var/log/nas_heartbeat.log`.

### Cron Suggestions

```bash
# Every 15 minutes for rapid detection
*/15 * * * * /path/to/omamount/nas_heartbeat.sh
# Daily comprehensive check
0 2 * * * /path/to/omamount/nas_heartbeat.sh
```

---

## 4. Boot/Network Timing Notes (General)

On some systems, network-online readiness can lag behind login, which can cause first-access CIFS failures (e.g., `cifs_mount failed w/return code = -101`). This setup avoids boot-time mounting and relies on systemd automount plus (optional) `NetworkManager-wait-online.service`.

### Step 1: Re-run the provisioning script

```bash
./networking/setup_nas_mounts.sh
```

### Step 2: Ensure the network wait unit is active

```bash
sudo systemctl enable --now NetworkManager-wait-online.service
```

### Step 4: Confirm automount metadata is present

Each `/etc/fstab` line should include:

```text
noauto,x-systemd.automount,x-systemd.requires=network-online.target,x-systemd.after=network-online.target
```

These options convert each share into an automount that only attaches once the network is ready.

---

## 5. Post-Setup Verification

```bash
mount | grep /mnt/nas
ls -l /mnt/nas
journalctl -b --no-pager | grep -i cifs
```

All shares should show as mounted without `-101` errors after the boot-time remount service runs.

---

## 6. Rollback Checklist

1. `sudo umount /mnt/nas/*`
2. `sudo sed -i '/192\.168\.8\.117/d' /etc/fstab`
3. `sudo rm -rf /mnt/nas`
4. `sudo rm -f /etc/samba/credentials/omarchy-nas.creds`
5. (Optional) `sudo rm -f /etc/systemd/system/omarchy-nas-mounts.service && sudo systemctl daemon-reload`

Or use the script:

```bash
./networking/setup_nas_mounts.sh --uninstall
```

---

## References

- `networking/setup_nas_mounts.sh`
- `networking/shares.md` (detailed NAS provisioning notes)
- `networking/README.md`
