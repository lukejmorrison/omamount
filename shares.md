# Synology NAS Shares Setup Documentation

## Overview

`networking/setup_nas_mounts.sh` provisions Synology (or any SMB) shares on Omarchy (Arch Linux) with hardened defaults: credential isolation, idempotent `/etc/fstab` management, and systemd automounting so mounts happen on first access instead of blocking boot.

## Checklist

- Install packages: `nfs-common`, `cifs-utils`
- Install packages: `cifs-utils`
- Prompt for NAS credentials and create `/etc/samba/credentials/omarchy-nas.creds` (root-owned, chmod `600`)
- Copy `networking/nas_config.example.sh` to `networking/nas_config.local.sh` and define the NAS + share list there
- Create mount points under `/mnt/nas/` for every share defined by the config/script
- Write optimized CIFS entries to `/etc/fstab` (on-demand automount, SMB3 + encryption)
- Optionally enable `NetworkManager-wait-online.service` (if present)
- Run mounts once for immediate verification

## fstab entries

This document intentionally does not duplicate the full share list. Treat the script output as authoritative:

```bash
./networking/setup_nas_mounts.sh --print-fstab
```

The script writes these entries into `/etc/fstab` inside a clearly marked managed block:

- `# BEGIN OMAMOUNT`
- `# END OMAMOUNT`

```bash
//NAS_HOST_OR_IP/share1 /mnt/nas/share1 cifs credentials=/etc/samba/credentials/omarchy-nas.creds,vers=3.1.1,seal,uid=1000,gid=1000,file_mode=0664,dir_mode=0775,nosuid,nodev,_netdev,nofail,noauto,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,mfsymlinks 0 0
//NAS_HOST_OR_IP/share2 /mnt/nas/share2 cifs credentials=/etc/samba/credentials/omarchy-nas.creds,vers=3.1.1,seal,uid=1000,gid=1000,file_mode=0664,dir_mode=0775,nosuid,nodev,_netdev,nofail,noauto,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,mfsymlinks 0 0
```

The script computes `uid`/`gid` from the invoking user so ownership mapping matches your Omarchy user.

### Option rationale

- `vers=3.0`, `seal`: force SMB3 with encryption when available
- `vers=3.1.1`, `seal`: prefer modern SMB3 with encryption when available
- `uid=…`, `gid=…`, `file_mode`, `dir_mode`: map ownership to the local user
- `nosuid,nodev`: safer defaults for network mounts
- `_netdev`, `nofail`: keep boot resilient if the NAS is offline
- `noauto`, `x-systemd.automount`: convert each share into an automount unit (no boot delay)
- `x-systemd.requires=network-online.target`, `x-systemd.after=network-online.target`: wait for NetworkManager to complete link negotiation

## Usage

```bash
chmod +x networking/setup_nas_mounts.sh
./networking/setup_nas_mounts.sh
```

### Audit / preview (no changes)

```bash
./networking/setup_nas_mounts.sh --list
./networking/setup_nas_mounts.sh --print-fstab
./networking/setup_nas_mounts.sh --doctor
```

### Uninstall

```bash
./networking/setup_nas_mounts.sh --uninstall
```

The script offers to recreate the credentials file if it already exists—use this when passwords change or the NAS rejects the stored login. After credentials are confirmed, it pushes updated entries to `/etc/fstab`, reloads systemd, and mounts once so you can verify immediately.

## Verification

```bash
grep -n "OMAMOUNT" /etc/fstab
mount | grep /mnt/nas
```

## Idempotency

- The script removes only its own marked `/etc/fstab` block before writing a new one.
- Existing credentials are preserved; re-running the script skips credential creation.

## Rollback

```bash
sudo umount /mnt/nas/*
sudo sed -i '/192\.168\.8\.117/d' /etc/fstab
sudo rm -rf /mnt/nas
sudo rm -f /etc/samba/credentials/omarchy-nas.creds
```

## Troubleshooting

- `journalctl -b --no-pager | grep -i cifs` – inspect mount failures at boot
- `sudo mount -a -t cifs` – manually retry mounts after fixing connectivity
- Ensure `NetworkManager-wait-online.service` is active: `systemctl is-enabled NetworkManager-wait-online.service`
- If a share reports `NT_STATUS_LOGON_FAILURE`, rerun `setup_nas_mounts.sh` and choose to recreate the credentials file.

## Hardening notes

- If a share should never execute binaries, consider adding `noexec` to that share’s mount options.
- If you don’t need encryption on a trusted LAN, you can drop `seal` for slightly lower overhead—but Omarchy defaults should bias toward safety.
