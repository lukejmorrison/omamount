# omamount

An opinionated, “omakase” NAS-mounting setup for Linux.

Curated defaults (systemd automounts, hardened CIFS, idempotent `/etc/fstab`). You bring the NAS details. You own the outcome.

## Omakase Disclaimer

- Do what you want, but don’t blame me if your mounts go rogue.
- This repo ships **no real hostnames/IPs/share names**. Put them in `nas_config.local.sh` (gitignored).
- Credentials never belong in the repo.
- We aim for sane defaults, not guarantees. Verify on your hardware.

## Contents

- `setup_nas_mounts.sh` – Provisions SMB/CIFS NAS shares under `/mnt/nas/` (or `$MOUNT_ROOT`), stores credentials securely under `/etc/samba/credentials/`, and writes systemd-friendly `/etc/fstab` entries.
- `nas_config.example.sh` – Example config (safe to commit). Copy to `nas_config.local.sh` and edit.
- `nas_config.local.example.sh` – Example per-machine override file (copy to `nas_config.local.sh`).
- `networkingsetup.md` – High-level Omarchy guide for provisioning, verification, rollback, and troubleshooting.
- `shares.md` – Notes on options, security posture, rollback, and troubleshooting.
- `LICENSE` – MIT License.

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

## Install On A New Machine

```bash
git clone https://github.com/lukejmorrison/omamount.git
cd omamount
cp nas_config.example.sh nas_config.local.sh
$EDITOR nas_config.local.sh

./setup_nas_mounts.sh --doctor
./setup_nas_mounts.sh --apply
```

After provisioning, shares mount on first access (automount) and won’t stall boot if the NAS is offline.

## Operating Principles

- Prefer “convention over configuration”: keep mount roots and share names stable.
- Keep credentials root-owned and out of user home directories.
- Use automounts (`x-systemd.automount`) instead of boot-time hard mounts.

For maintenance conventions in this folder (how to document changes, what to avoid), see `AGENTS.md`.

## License

MIT. See `LICENSE`.
