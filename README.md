# Networking (Omarchy)

This folder is the maintained, “Omarchy-aligned” place for your Arch Linux networking/NAS setup: one script to provision mounts, plus documentation you can keep current as your share layout evolves.

## Contents

- `setup_nas_mounts.sh` – Provisions SMB/CIFS NAS shares under `/mnt/nas/` (or `$MOUNT_ROOT`), stores credentials securely under `/etc/samba/credentials/`, and writes systemd-friendly `/etc/fstab` entries.
- `nas_config.example.sh` – Example config (safe to commit). Copy to `nas_config.local.sh` and edit.
- `nas_config.local.example.sh` – Example per-machine override file (copy to `nas_config.local.sh`).
- `networkingsetup.md` – High-level Omarchy guide for provisioning, verification, rollback, and troubleshooting.
- `shares.md` – Notes on options, security posture, rollback, and troubleshooting.

## Quick Start (SMB shares)

```bash
cd networking
chmod +x setup_nas_mounts.sh

# Configure (local-only; gitignored)
cp nas_config.example.sh nas_config.local.sh
$EDITOR nas_config.local.sh

./setup_nas_mounts.sh --doctor
./setup_nas_mounts.sh --apply
```

Health check (no changes):

```bash
./setup_nas_mounts.sh --doctor
```

## Install On A New Machine

```bash
git clone https://github.com/lukejmorrison/omamount.git
cd omamount
cp nas_config.example.sh nas_config.local.sh
$EDITOR nas_config.local.sh

./setup_nas_mounts.sh --doctor
./setup_nas_mounts.sh --apply
```

After provisioning, the shares are configured as systemd automounts: they mount on first access and won’t stall boot if your NAS is offline.

## Operating Principles

- Prefer “convention over configuration”: keep mount roots and share names stable.
- Keep credentials root-owned and out of user home directories.
- Use automounts (`x-systemd.automount`) instead of boot-time hard mounts.

For maintenance conventions in this folder (how to document changes, what to avoid), see `AGENTS.md`.
