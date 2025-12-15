#!/usr/bin/env bash

# omamount: Provision SMB/CIFS NAS mounts (portable Linux)
#
# Goals:
# - Secure credential storage (root-readable only)
# - Idempotent /etc/fstab management
# - systemd automount (no boot delays; mounts on first access)
# - Hardened mount defaults (SMB3.1.1, encryption when supported, nosuid/nodev)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration (NAS host/IP + mount root + share list).
#
# This repo intentionally does NOT ship real IPs, hostnames, or share names.
# Put your real values in a local, ignored file.
#
# Order of precedence:
# 1) Environment variables (NAS_IP/MOUNT_ROOT/SHARES) set by caller
# 2) CONFIG_FILE=/path/to/config.sh (optional)
# 3) Local override file: networking/nas_config.local.sh (recommended; gitignored)
CONFIG_FILE="${CONFIG_FILE:-}"

if [[ -n "${CONFIG_FILE}" && -r "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

if [[ -r "${SCRIPT_DIR}/nas_config.local.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/nas_config.local.sh"
fi

NAS_IP="${NAS_IP:-}"
MOUNT_ROOT="${MOUNT_ROOT:-/mnt/nas}"

# Keep credentials out of $HOME. This file must be owned by root and mode 600.
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/etc/samba/credentials/omarchy-nas.creds}"

require_config() {
    if [[ -z "${NAS_IP}" || ${#SHARES[@]:-0} -eq 0 ]]; then
        echo "Missing config (NAS_IP and/or SHARES)." >&2
        echo >&2
        echo "To configure:" >&2
        echo "  1) Copy: ${SCRIPT_DIR}/nas_config.example.sh -> ${SCRIPT_DIR}/nas_config.local.sh" >&2
        echo "  2) Edit nas_config.local.sh with your NAS host/IP and shares" >&2
        echo >&2
        echo "nas_config.local.sh is gitignored so your network details stay private." >&2
        exit 2
    fi
}

if [[ -n "${NAS_IP}" ]]; then
    echo "[omamount] Provisioning NAS mounts from ${NAS_IP} -> ${MOUNT_ROOT}"
else
    echo "[omamount] NAS config not loaded yet (run --help for setup)"
fi

FSTAB_BEGIN="# BEGIN OMAMOUNT"
FSTAB_END="# END OMAMOUNT"

usage() {
	cat <<'EOF'
Usage:
    setup_nas_mounts.sh                Provision mounts (installs deps, writes fstab, mounts)
    setup_nas_mounts.sh --apply        Same as running with no args
    setup_nas_mounts.sh --list         Show current config + share list (no changes)
    setup_nas_mounts.sh --print-fstab  Print the fstab lines that would be written (no changes)
    setup_nas_mounts.sh --doctor       Check dependencies + config health (no changes)
    setup_nas_mounts.sh --uninstall    Remove managed fstab block (prompts for extras)
    setup_nas_mounts.sh --help         Show this help

Environment overrides:
    CONFIG_FILE=/path/to/config.sh ./setup_nas_mounts.sh
    NAS_IP=<host_or_ip> MOUNT_ROOT=<path> CREDENTIALS_FILE=<path> ./setup_nas_mounts.sh

Config files:
    - Copy nas_config.example.sh to nas_config.local.sh and edit it (recommended).
EOF
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

is_systemd() {
    [[ -d /run/systemd/system ]] && have_cmd systemctl
}

detect_pkg_manager() {
    if have_cmd pacman; then
        echo "pacman"
        return
    fi
    if have_cmd apt-get; then
        echo "apt"
        return
    fi
    if have_cmd dnf; then
        echo "dnf"
        return
    fi
    if have_cmd zypper; then
        echo "zypper"
        return
    fi
    echo "unknown"
}

install_cifs_utils() {
    # If the helper exists, the dependency is already present.
    if have_cmd mount.cifs; then
        return 0
    fi

    local pm
    pm="$(detect_pkg_manager)"
    case "${pm}" in
        pacman)
            sudo pacman -Sy --noconfirm --needed cifs-utils
            ;;
        apt)
            sudo apt-get update
            sudo apt-get install -y cifs-utils
            ;;
        dnf)
            sudo dnf install -y cifs-utils
            ;;
        zypper)
            sudo zypper --non-interactive in cifs-utils
            ;;
        *)
            echo "Could not detect a supported package manager to install cifs-utils." >&2
            echo "Install it manually (package usually named 'cifs-utils'), then re-run." >&2
            return 1
            ;;
    esac

    have_cmd mount.cifs
}

get_target_user() {
    # Prefer the invoking user when running via sudo.
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "${SUDO_USER}"
        return
    fi
    echo "${USER}"
}

get_uid_gid() {
    local target_user
    target_user="$(get_target_user)"
    local uid gid
    uid="$(id -u "${target_user}" 2>/dev/null || true)"
    gid="$(id -g "${target_user}" 2>/dev/null || true)"
    if [[ -z "${uid}" || -z "${gid}" ]]; then
        uid="1000"
        gid="1000"
    fi
    echo "${uid}:${gid}"
}

print_config() {
    require_config
    local uid_gid
    uid_gid="$(get_uid_gid)"
    local uid="${uid_gid%%:*}"
    local gid="${uid_gid##*:}"

    echo "NAS_IP=${NAS_IP}"
    echo "MOUNT_ROOT=${MOUNT_ROOT}"
    echo "CREDENTIALS_FILE=${CREDENTIALS_FILE}"
    echo "UID=${uid}"
    echo "GID=${gid}"
    echo "SHARES:"
    for share in "${SHARES[@]}"; do
        echo "  - ${share}"
    done
}

print_fstab_entries() {
    require_config
    local uid_gid
    uid_gid="$(get_uid_gid)"
    local uid="${uid_gid%%:*}"
    local gid="${uid_gid##*:}"

    local mount_options
    mount_options="credentials=${CREDENTIALS_FILE},vers=3.1.1,seal,uid=${uid},gid=${gid},file_mode=0664,dir_mode=0775,nosuid,nodev,_netdev,nofail,noauto,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.requires=network-online.target,x-systemd.after=network-online.target,mfsymlinks"

    for share in "${SHARES[@]}"; do
        local remote="//${NAS_IP}/${share}"
        local mount_point="${MOUNT_ROOT}/${share}"
        echo "${remote} ${mount_point} cifs ${mount_options} 0 0"
    done
}

build_fstab_block() {
    echo "${FSTAB_BEGIN}"
    echo "# Managed by omamount: $(basename "$0")"
    print_fstab_entries
    echo "${FSTAB_END}"
}

write_fstab_block() {
    local backup tmp
    require_config
    backup="/etc/fstab.omamount-bak.$(date +%Y%m%d%H%M%S)"
    tmp="$(mktemp)"

    # Remove any previous managed block, and also remove legacy lines for the same NAS+root
    # to avoid duplicating mounts when migrating to block management.
    sudo awk \
        -v begin="${FSTAB_BEGIN}" \
        -v end="${FSTAB_END}" \
        -v nas="//${NAS_IP}/" \
        -v root="${MOUNT_ROOT}/" \
        'BEGIN{inblock=0}
         $0==begin {inblock=1; next}
         $0==end {inblock=0; next}
         inblock==1 {next}
         (index($1,nas)==1 && index($2,root)==1) {next}
         {print}' \
        /etc/fstab | sudo tee "${tmp}" >/dev/null

    build_fstab_block | sudo tee -a "${tmp}" >/dev/null

    sudo cp -a /etc/fstab "${backup}"
    sudo cp "${tmp}" /etc/fstab
    rm -f "${tmp}"

    echo "Updated /etc/fstab (backup: ${backup})"
}

doctor() {
    require_config
    local ok=1

    echo "[doctor] Checking environment"
    echo "  pkg_manager=$(detect_pkg_manager)"
    echo "  systemd=$(is_systemd && echo yes || echo no)"

    echo "[doctor] Checking dependencies"
    if have_cmd mount.cifs; then
        echo "  [OK] mount.cifs present"
    else
        echo "  [WARN] mount.cifs missing (install cifs-utils)"
        ok=0
    fi

    echo "[doctor] Checking credentials"
    if sudo test -f "${CREDENTIALS_FILE}"; then
        echo "  [OK] credentials file exists: ${CREDENTIALS_FILE}"
        # Best-effort permission checks.
        local mode owner group
        mode="$(sudo stat -c '%a' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
        owner="$(sudo stat -c '%U' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
        group="$(sudo stat -c '%G' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
        if [[ "${mode}" != "600" || "${owner}" != "root" ]]; then
            echo "  [WARN] expected root-owned 600 perms (got ${owner}:${group} ${mode})"
            ok=0
        fi
    else
        echo "  [WARN] credentials file missing: ${CREDENTIALS_FILE}"
        ok=0
    fi

    echo "[doctor] Checking /etc/fstab"
    if grep -qxF "${FSTAB_BEGIN}" /etc/fstab 2>/dev/null && grep -qxF "${FSTAB_END}" /etc/fstab 2>/dev/null; then
        echo "  [OK] managed block markers present"
    else
        echo "  [WARN] managed block markers not found (run --apply once)"
        ok=0
    fi

    echo "[doctor] Checking mount points"
    for share in "${SHARES[@]}"; do
        if [[ -d "${MOUNT_ROOT}/${share}" ]]; then
            :
        else
            echo "  [WARN] missing directory: ${MOUNT_ROOT}/${share}"
            ok=0
        fi
    done

    if [[ "${ok}" -eq 1 ]]; then
        echo "[doctor] OK"
        return 0
    fi

    echo "[doctor] Issues found"
    return 1
}

uninstall() {
    echo "This will remove the managed OMARCHY-NAS block from /etc/fstab."
    read -rp "Continue? [y/N]: " confirm
    if [[ "${confirm,,}" != y && "${confirm,,}" != yes ]]; then
        echo "Aborted."
        return 1
    fi

    local backup tmp
    backup="/etc/fstab.omamount-bak.$(date +%Y%m%d%H%M%S)"
    tmp="$(mktemp)"

    sudo awk -v begin="${FSTAB_BEGIN}" -v end="${FSTAB_END}" 'BEGIN{inblock=0}
        $0==begin {inblock=1; next}
        $0==end {inblock=0; next}
        inblock==1 {next}
        {print}' /etc/fstab | sudo tee "${tmp}" >/dev/null

    sudo cp -a /etc/fstab "${backup}"
    sudo cp "${tmp}" /etc/fstab
    rm -f "${tmp}"
    echo "Removed managed block from /etc/fstab (backup: ${backup})"

    read -rp "Remove credentials file ${CREDENTIALS_FILE}? [y/N]: " rmcreds
    if [[ "${rmcreds,,}" == y || "${rmcreds,,}" == yes ]]; then
        sudo rm -f "${CREDENTIALS_FILE}"
        echo "Removed ${CREDENTIALS_FILE}"
    fi

    read -rp "Remove mount root ${MOUNT_ROOT}? [y/N]: " rmmount
    if [[ "${rmmount,,}" == y || "${rmmount,,}" == yes ]]; then
        sudo rm -rf "${MOUNT_ROOT}"
        echo "Removed ${MOUNT_ROOT}"
    fi

    return 0
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    --apply)
        ;;
    --list|-l)
        print_config
        exit 0
        ;;
    --print-fstab)
        print_fstab_entries
        exit 0
        ;;
    --doctor)
        doctor
        exit $?
        ;;
    --uninstall)
        uninstall
        exit $?
        ;;
    "")
        ;;
    *)
        echo "Unknown argument: ${1}" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac

# Function to install packages
install_packages() {
    echo "Installing necessary packages..."
    install_cifs_utils
}

# Function to create secure credentials file
create_credentials() {
    if sudo test -f "${CREDENTIALS_FILE}"; then
        read -rp "Credentials file exists at ${CREDENTIALS_FILE}. Recreate it? [y/N]: " recreate
        if [[ "${recreate,,}" != y && "${recreate,,}" != yes ]]; then
            echo "Reusing existing credentials at ${CREDENTIALS_FILE}"
            return
        fi
    fi

    read -rp "Enter NAS username: " nas_user
    read -srp "Enter NAS password: " nas_pass
    echo

    sudo install -d -m 0700 "$(dirname "${CREDENTIALS_FILE}")"
    sudo rm -f "${CREDENTIALS_FILE}"
    {
        echo "username=${nas_user}";
        echo "password=${nas_pass}";
    } | sudo tee "${CREDENTIALS_FILE}" > /dev/null
    sudo chown root:root "${CREDENTIALS_FILE}"
    sudo chmod 600 "${CREDENTIALS_FILE}"

    echo "Credentials written to ${CREDENTIALS_FILE} (root:root, 600)"
}

# Function to create mount points
create_mount_points() {
	echo "Creating mount point directories under ${MOUNT_ROOT}/..."
	for share in "${SHARES[@]}"; do
		sudo mkdir -p "${MOUNT_ROOT}/${share}"
	done
}

# Function to add shares to fstab with optimized options
add_shares_to_fstab() {
	echo "Adding hardened share entries to /etc/fstab (managed block)..."
	write_fstab_block
}

configure_systemd() {
    echo "Ensuring network-online integration (systemd)..."

    # Omarchy typically uses NetworkManager; if the wait-online unit exists, enable it.
    if is_systemd && systemctl list-unit-files | grep -q '^NetworkManager-wait-online\.service'; then
		sudo systemctl enable --now NetworkManager-wait-online.service
	fi

    # With x-systemd.automount in fstab, a dedicated remount service is usually unnecessary.
    # Keep a small oneshot helper available for manual recovery.
    if ! is_systemd; then
		echo "systemd not detected; skipping helper service installation."
		return 0
	fi

    sudo tee /etc/systemd/system/omarchy-nas-mounts.service > /dev/null <<'EOF'
[Unit]
Description=Mount Omarchy NAS CIFS shares
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/mount -a -t cifs

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
}

# Function to mount all shares
mount_shares() {
    echo "Mounting all shares (or triggering automount)..."
    local failures=()

    for share in "${SHARES[@]}"; do
        local mount_point="${MOUNT_ROOT}/${share}"
        local output=""

        if mountpoint -q "${mount_point}"; then
            echo "  [SKIP] ${mount_point} already mounted"
            continue
        fi

        # Mount explicitly once so verification is immediate.
        if output=$(sudo mount "${mount_point}" 2>&1); then
            echo "  [OK] ${mount_point}"
        else
            echo "  [FAIL] ${mount_point} -> ${output}"
            failures+=("${share}")
        fi
    done

    if ((${#failures[@]})); then
        echo "Warning: the following shares could not be mounted: ${failures[*]}"
    else
        echo "All shares mounted successfully!"
    fi
}

# Function to verify mounts
verify_mounts() {
	echo "Verifying mounts..."
	local missing=()

	for share in "${SHARES[@]}"; do
		local mount_point="${MOUNT_ROOT}/${share}"
		if mountpoint -q "${mount_point}"; then
			echo "  [OK] ${mount_point}"
		else
			echo "  [MISSING] ${mount_point} is not mounted"
			missing+=("${share}")
		fi
	done

	ls -la "${MOUNT_ROOT}/" || true

	if ((${#missing[@]})); then
		echo "Warning: the following shares are not currently mounted: ${missing[*]}"
	fi
}

# Main function
main() {
    require_config
	install_packages
	create_credentials
	create_mount_points
	add_shares_to_fstab
	configure_systemd
	mount_shares
	verify_mounts
	echo "Setup complete! NAS shares are configured under ${MOUNT_ROOT}/"
	echo "Tip: With systemd automount, shares will come up on first access even if the NAS is offline at boot."
}

main
