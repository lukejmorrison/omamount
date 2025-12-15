# AGENTS.md: Omarchy Networking Maintenance Protocol

This folder is the “single source of truth” for networking and NAS share setup for Omarchy (Arch Linux). The goal is to keep it simple, secure by default, and easy to re-apply on a fresh machine.

## 1. The Philosophy (Omakase)

- **Prefer the happy path**: systemd automounts and root-owned credentials.
- **Avoid configuration sprawl**: one script provisions mounts; docs explain the choices.
- **Security is a feature**: network mounts are an attack surface; default to hardened options.

## 2. Conventions

### 2.1 Credentials

- Credentials must be stored **outside user home directories**.
- Default location used by this workspace:
  - `/etc/samba/credentials/omarchy-nas.creds`
- Permissions must be:
  - directory: `0700`
  - file: `0600`, owned by `root:root`

### 2.2 Mount root

- Default mount root: `/mnt/nas`
- Mount points follow share names: `/mnt/nas/<share>`

### 2.3 fstab policy

- Prefer:
  - `noauto,x-systemd.automount` (mount on first access)
  - `_netdev,nofail` (don’t block boot)
  - `vers=3.1.1,seal` when supported (modern SMB + encryption)
  - `nosuid,nodev` as baseline hardening
- Avoid:
  - storing passwords inline in `/etc/fstab`
  - putting credentials under `$HOME`

## 3. What “Done” Looks Like

When this folder is in a good state:

- `setup_nas_mounts.sh` can be run on a clean Omarchy install and produces working mounts.
- `networking/README.md` matches the actual contents of this folder.
- `shares.md` documents the hardened defaults and rollback steps.

## 4. Change Logging

This workspace has two explicit logging protocols:

- **Fixes (PLOG)**: Only when the user says “File a PLOG.”
- **Customizations**: Only when the user says “File a customization.”

Networking changes are usually “maintenance,” not necessarily a PLOG/customization. If the user asks for either protocol explicitly, follow the workspace-wide rules in:

- `ProblemLogs/AGENTS.md`
- `Customizations/AGENTS.md`

## 5. Safe Workflow for Updating Shares

1. Update the share list and defaults in `setup_nas_mounts.sh`.
2. Re-run the script.
3. Verify:
   - `mount | grep /mnt/nas`
   - `systemctl list-units | grep -i mnt-nas`
4. Update `shares.md` if mount options or credential locations changed.
