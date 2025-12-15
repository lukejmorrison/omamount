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

shares_count() {
    # With `set -u`, referencing an unset array errors.
    # This helper safely reports 0 if SHARES is unset or not an array.
    local decl
    decl="$(declare -p SHARES 2>/dev/null || true)"
    if [[ "${decl}" == declare\ -a\ SHARES* ]]; then
        echo "${#SHARES[@]}"
        return 0
    fi
    echo 0
}

get_home_dir() {
    local target_user
    target_user="$1"

    local home
    home="$(getent passwd "${target_user}" 2>/dev/null | cut -d: -f6 || true)"
    if [[ -n "${home}" ]]; then
        echo "${home}"
        return 0
    fi

    # Best-effort fallback.
    echo "/home/${target_user}"
}

require_config() {
    local count
    count="$(shares_count)"

    if [[ -z "${NAS_IP}" || "${count}" -eq 0 ]]; then
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
    echo "[omamount] Config loaded: NAS_IP=${NAS_IP} MOUNT_ROOT=${MOUNT_ROOT}"
else
    echo "[omamount] Config not loaded yet (run without args for help)"
fi

FSTAB_BEGIN="# BEGIN OMAMOUNT"
FSTAB_END="# END OMAMOUNT"

usage() {
	cat <<'EOF'
Usage:
    setup_nas_mounts.sh                Show help and configuration instructions
    setup_nas_mounts.sh --apply        Provision mounts (installs deps, writes fstab, mounts)
    setup_nas_mounts.sh --wizard       Guided setup (checks + interactive fixes)
    setup_nas_mounts.sh --list         Show current config + share list (no changes)
    setup_nas_mounts.sh --print-fstab  Print the fstab lines that would be written (no changes)
    setup_nas_mounts.sh --doctor       Check dependencies + config health (no changes)
    setup_nas_mounts.sh --uninstall    Remove managed fstab block (prompts for extras)
    setup_nas_mounts.sh --help         Show this help

Quick start:
    1) cp ./nas_config.example.sh ./nas_config.local.sh
    2) Edit nas_config.local.sh:
         - Set NAS_IP to your NAS hostname/IP
         - Set SHARES to your SMB share names
    3) ./setup_nas_mounts.sh --wizard
    4) ./setup_nas_mounts.sh --apply

Example SHARES (share names only, no //host prefix):
    SHARES=("share1" "share2")

Environment overrides:
    CONFIG_FILE=/path/to/config.sh ./setup_nas_mounts.sh
    NAS_IP=<host_or_ip> MOUNT_ROOT=<path> CREDENTIALS_FILE=<path> ./setup_nas_mounts.sh

Config files:
    - Copy nas_config.example.sh to nas_config.local.sh and edit it (recommended).

Common fix:
    If you see: "install: cannot create directory '/etc/samba/credentials': File exists"
    it means /etc/samba/credentials is a file (some setups use it that way).
    The script will offer to back it up and create the directory it needs.
EOF
}

ask_yes_no() {
    # ask_yes_no "Question?" default_yes
    # default_yes: "y" or "n"
    local prompt="$1"
    local default_yes="${2:-y}"
    local reply

    if [[ "${default_yes}" == y ]]; then
        read -rp "${prompt} [Y/n]: " reply
        reply="${reply:-y}"
    else
        read -rp "${prompt} [y/N]: " reply
        reply="${reply:-n}"
    fi

    reply="${reply,,}"
    [[ "${reply}" == y || "${reply}" == yes ]]
}

wizard() {
    echo
    echo "[omamount wizard] Guided setup"
    echo "This will check your setup and offer fixes step-by-step."
    echo "Note: You'll be asked for sudo first (LOCAL password), then NAS SMB credentials later."
    echo

    require_config

    local issues=0

    echo "[1/6] Checking dependencies"
    if have_cmd mount.cifs; then
        echo "  [OK] cifs-utils present (mount.cifs)"
    else
        echo "  [WARN] cifs-utils missing (mount.cifs not found)"
        issues=1
        if ask_yes_no "Install cifs-utils now?" y; then
            install_packages
        fi
    fi

    echo
    echo "[2/6] Checking credentials file"
    if sudo test -f "${CREDENTIALS_FILE}"; then
        echo "  [OK] ${CREDENTIALS_FILE} exists"

        local mode owner group
        mode="$(sudo stat -c '%a' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
        owner="$(sudo stat -c '%U' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
        group="$(sudo stat -c '%G' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
        if [[ "${mode}" != "600" || "${owner}" != "root" ]]; then
            echo "  [WARN] expected root-owned 600 perms (got ${owner}:${group} ${mode})"
            issues=1
            if ask_yes_no "Fix permissions to root:root 600?" y; then
                sudo chown root:root "${CREDENTIALS_FILE}" || true
                sudo chmod 600 "${CREDENTIALS_FILE}" || true
            fi
        fi
    else
        echo "  [WARN] missing: ${CREDENTIALS_FILE}"
        issues=1
        if ask_yes_no "Create credentials file now?" y; then
            create_credentials
        fi
    fi

    echo
    echo "[3/6] Checking mount points"
    local missing_dirs=()
    for share in "${SHARES[@]}"; do
        if [[ ! -d "${MOUNT_ROOT}/${share}" ]]; then
            missing_dirs+=("${share}")
        fi
    done
    if ((${#missing_dirs[@]})); then
        echo "  [WARN] missing ${#missing_dirs[@]} mount point(s) under ${MOUNT_ROOT}" 
        issues=1
        if ask_yes_no "Create missing mount point directories now?" y; then
            create_mount_points
        fi
    else
        echo "  [OK] mount points exist"
    fi

    echo
    echo "[4/6] Checking /etc/fstab managed block"
    if grep -qxF "${FSTAB_BEGIN}" /etc/fstab 2>/dev/null && grep -qxF "${FSTAB_END}" /etc/fstab 2>/dev/null; then
        echo "  [OK] OMAMOUNT markers present"
    else
        echo "  [WARN] OMAMOUNT markers not found"
        issues=1
        if ask_yes_no "Write the OMAMOUNT managed block to /etc/fstab now?" y; then
            if ! add_shares_to_fstab; then
                echo "  [FAIL] Could not update /etc/fstab." >&2
                echo "  [HINT] Try: sudo -v (ensure sudo works), then re-run --wizard or --apply." >&2
                echo "  [HINT] You can also preview the entries with: --print-fstab" >&2
                return 1
            fi
        fi
    fi

    echo
    echo "[5/6] systemd integration"
    if is_systemd; then
        echo "  [OK] systemd detected"
        if ask_yes_no "Enable network-online integration (recommended)?" y; then
            configure_systemd
        fi
    else
        echo "  [INFO] systemd not detected; skipping"
    fi

    echo
    echo "[6/6] Next step"
    if [[ "${issues}" -eq 0 ]]; then
        echo "  [OK] Preflight looks good."
    else
        echo "  [INFO] Preflight found warnings (some may still remain if you declined fixes)."
    fi

    echo
    echo "Wizard summary:"
    echo "  NAS:    //${NAS_IP}/<share>"
    echo "  Mounts: ${MOUNT_ROOT}/<share>"
    echo "  Shares: $(shares_count)"
    echo

    if ask_yes_no "Run full provisioning now (same as --apply)?" y; then
        apply_provision
    else
        echo "You can run: ./setup_nas_mounts.sh --apply when ready."
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

require_sudo() {
    # Many operations touch /etc (credentials, fstab, systemd units).
    # Make it explicit that this is the LOCAL machine password, not the NAS password.
    if [[ "${EUID}" -eq 0 ]]; then
        return 0
    fi

    echo "[omamount] Sudo is required for system changes (/etc, systemd, mounts)."
    echo "[omamount] IMPORTANT: enter your LOCAL Linux password for user '${USER}' (NOT your NAS password)."
    echo "[omamount] If you accidentally typed the NAS password repeatedly, you may be temporarily locked out." 
    echo

    if ! sudo -v -p "[sudo/local] Password for %u (LOCAL machine, not NAS): "; then
        echo "[omamount] sudo authentication failed." >&2
        echo "[omamount] Fix: run 'sudo -v' in a terminal and enter your local password, then re-run." >&2
        return 1
    fi
    return 0
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
    # Create the temp file as root to avoid edge cases where sudo/root cannot
    # write to a user-owned temp file under a sticky directory like /tmp.
    tmp="$(sudo mktemp /tmp/omamount.fstab.XXXXXX)"

        # Remove any previous managed block.
        # Also remove legacy CIFS entries for the SAME mountpoints (under MOUNT_ROOT/<share>)
        # regardless of remote host, to avoid conflicts (common if user previously had a manual line).
    if ! sudo awk \
        -v begin="${FSTAB_BEGIN}" \
        -v end="${FSTAB_END}" \
                -v root="${MOUNT_ROOT}" \
                -v shares_csv="$(IFS=,; echo "${SHARES[*]}")" \
        'BEGIN{inblock=0}
                 BEGIN{
                     n=split(shares_csv, a, ",");
                     for(i=1;i<=n;i++){
                         m[root "/" a[i]]=1;
                     }
                 }
         $0==begin {inblock=1; next}
         $0==end {inblock=0; next}
         inblock==1 {next}
                 ($3=="cifs" && ($2 in m)) {next}
         {print}' \
        /etc/fstab | sudo tee "${tmp}" >/dev/null; then
        echo "Failed to build temporary fstab file at ${tmp}" >&2
        sudo rm -f "${tmp}" || true
        return 1
    fi

    if ! build_fstab_block | sudo tee -a "${tmp}" >/dev/null; then
        echo "Failed to append OMAMOUNT block to temporary fstab file at ${tmp}" >&2
        sudo rm -f "${tmp}" || true
        return 1
    fi

    sudo cp -a /etc/fstab "${backup}"
    sudo cp "${tmp}" /etc/fstab
    sudo rm -f "${tmp}"

    # systemd generates mount/automount units from fstab; reload so changes take effect.
    if is_systemd; then
        sudo systemctl daemon-reload || true
    fi

    echo "Updated /etc/fstab (backup: ${backup})"
}

doctor() {
    require_config
    require_sudo || return 1
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
    require_sudo || return 1
    echo "This will remove the managed OMARCHY-NAS block from /etc/fstab."
    read -rp "Continue? [y/N]: " confirm
    if [[ "${confirm,,}" != y && "${confirm,,}" != yes ]]; then
        echo "Aborted."
        return 1
    fi

    local backup tmp
    backup="/etc/fstab.omamount-bak.$(date +%Y%m%d%H%M%S)"
    tmp="$(sudo mktemp /tmp/omamount.fstab.XXXXXX)"

    sudo awk -v begin="${FSTAB_BEGIN}" -v end="${FSTAB_END}" 'BEGIN{inblock=0}
        $0==begin {inblock=1; next}
        $0==end {inblock=0; next}
        inblock==1 {next}
        {print}' /etc/fstab | sudo tee "${tmp}" >/dev/null

    sudo cp -a /etc/fstab "${backup}"
    sudo cp "${tmp}" /etc/fstab
    sudo rm -f "${tmp}"
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

    local credentials_dir
    credentials_dir="$(dirname "${CREDENTIALS_FILE}")"

    # Some systems may have /etc/samba/credentials as a FILE.
    # We need it to be a directory (credentials_dir/omarchy-nas.creds).
    if sudo test -e "${credentials_dir}" && ! sudo test -d "${credentials_dir}"; then
        echo "A non-directory exists at ${credentials_dir}." >&2
        echo "omamount expects ${credentials_dir} to be a directory." >&2
        local backup
        backup="${credentials_dir}.bak.$(date +%Y%m%d%H%M%S)"
        read -rp "Move it to ${backup} and create ${credentials_dir}/ ? [y/N]: " fixdir
        if [[ "${fixdir,,}" == y || "${fixdir,,}" == yes ]]; then
            sudo mv "${credentials_dir}" "${backup}"
        else
            echo "Aborted. Alternative: set CREDENTIALS_FILE to a path whose parent is a directory." >&2
            echo "Example: CREDENTIALS_FILE=/etc/samba/omamount.creds ./setup_nas_mounts.sh --apply" >&2
            return 1
        fi
    fi

    # Ensure directory exists and is locked down.
    sudo install -d -m 0700 "${credentials_dir}"
    sudo chown root:root "${credentials_dir}" 2>/dev/null || true
    sudo chmod 0700 "${credentials_dir}" 2>/dev/null || true

    read -rp "Enter NAS SMB username (on the NAS): " nas_user
    echo "You entered username: ${nas_user}"
    if ! ask_yes_no "Is that correct?" y; then
        read -rp "Re-enter NAS SMB username (on the NAS): " nas_user
    fi

    read -srp "Enter NAS SMB password (on the NAS): " nas_pass
    echo

    sudo rm -f "${CREDENTIALS_FILE}"
    {
        echo "username=${nas_user}";
        echo "password=${nas_pass}";
    } | sudo tee "${CREDENTIALS_FILE}" > /dev/null
    sudo chown root:root "${CREDENTIALS_FILE}"
    sudo chmod 600 "${CREDENTIALS_FILE}"

    echo "Credentials written to ${CREDENTIALS_FILE} (root:root, 600)"

    if have_cmd smbclient; then
        echo "Validating SMB credentials against //${NAS_IP}..."

        local out rc
        set +e
        out="$(sudo smbclient -L "//${NAS_IP}" -A "${CREDENTIALS_FILE}" -m SMB3 2>&1)"
        rc=$?
        set -e

        if echo "${out}" | grep -qiE 'NT_STATUS_LOGON_FAILURE|session setup failed'; then
            echo "[FAIL] NAS rejected these SMB credentials (logon failure)." >&2
            echo "[HINT] Double-check NAS username/password, SMB enabled, and account not locked." >&2

            local try
            local validated=0
            for try in 1 2 3; do
                if ! ask_yes_no "Re-enter NAS SMB credentials now?" y; then
                    break
                fi

                read -rp "Enter NAS SMB username (on the NAS): " nas_user
                echo "You entered username: ${nas_user}"
                if ! ask_yes_no "Is that correct?" y; then
                    read -rp "Re-enter NAS SMB username (on the NAS): " nas_user
                fi

                read -srp "Enter NAS SMB password (on the NAS): " nas_pass
                echo

                sudo rm -f "${CREDENTIALS_FILE}"
                {
                    echo "username=${nas_user}";
                    echo "password=${nas_pass}";
                } | sudo tee "${CREDENTIALS_FILE}" > /dev/null
                sudo chown root:root "${CREDENTIALS_FILE}"
                sudo chmod 600 "${CREDENTIALS_FILE}"

                set +e
                out="$(sudo smbclient -L "//${NAS_IP}" -A "${CREDENTIALS_FILE}" -m SMB3 2>&1)"
                rc=$?
                set -e

                if ! echo "${out}" | grep -qiE 'NT_STATUS_LOGON_FAILURE|session setup failed'; then
                    echo "[OK] Credentials validated."
                    validated=1
                    break
                fi

                echo "[FAIL] Still failing SMB logon (attempt ${try}/3)." >&2
            done

            if [[ "${validated}" -ne 1 ]]; then
                if ! ask_yes_no "Proceed anyway (mounts will likely fail)?" n; then
                    echo "Aborting provisioning due to invalid SMB credentials." >&2
                    return 1
                fi
            fi
        else
            if [[ "${rc}" -eq 0 ]]; then
                echo "[OK] Credentials validated."
            else
                # Non-zero but not an auth failure; common warning is missing smb.conf.
                echo "[WARN] smbclient returned non-zero (${rc}) but did not report logon failure." >&2
                echo "[HINT] Continuing; mount step will be the final authority." >&2
            fi
        fi
    fi
}

add_files_bookmark() {
    # Adds a GNOME Files (Nautilus) bookmark to the mount root.
    local target_user home
    target_user="$(get_target_user)"
    home="$(get_home_dir "${target_user}")"
    local bookmarks_file
    bookmarks_file="${home}/.config/gtk-3.0/bookmarks"
    local uri
    uri="file://${MOUNT_ROOT}"

    mkdir -p "$(dirname "${bookmarks_file}")"
    touch "${bookmarks_file}"

    if grep -qF "${uri} " "${bookmarks_file}" 2>/dev/null || grep -qFx "${uri}" "${bookmarks_file}" 2>/dev/null; then
        echo "[omamount] Files bookmark already present: ${uri}"
        return 0
    fi

    echo "${uri} Omarchy NAS" >> "${bookmarks_file}"
    echo "[omamount] Added Files bookmark: Omarchy NAS -> ${MOUNT_ROOT}"
}

add_desktop_shortcut() {
    # Creates a symlink on the user's Desktop pointing to the mount root.
    local target_user home
    target_user="$(get_target_user)"
    home="$(get_home_dir "${target_user}")"

    local desktop_dir
    desktop_dir="${home}/Desktop"

    if [[ -r "${home}/.config/user-dirs.dirs" ]]; then
        # shellcheck disable=SC1090
        source "${home}/.config/user-dirs.dirs" || true
        if [[ -n "${XDG_DESKTOP_DIR:-}" ]]; then
            desktop_dir="${XDG_DESKTOP_DIR/#\$HOME/${home}}"
            desktop_dir="${desktop_dir%\"}"
            desktop_dir="${desktop_dir#\"}"
        fi
    fi

    mkdir -p "${desktop_dir}"

    local link_path
    link_path="${desktop_dir}/NAS"

    if [[ -L "${link_path}" || -e "${link_path}" ]]; then
        echo "[omamount] Desktop shortcut already exists: ${link_path}"
        return 0
    fi

    ln -s "${MOUNT_ROOT}" "${link_path}"
    echo "[omamount] Created Desktop shortcut: ${link_path} -> ${MOUNT_ROOT}"
}

add_home_shortcut() {
    # Creates a symlink in the user's home directory pointing to the mount root.
    # This is the most reliable “shortcut” for terminal workflows (works regardless of desktop icons).
    local target_user home
    target_user="$(get_target_user)"
    home="$(get_home_dir "${target_user}")"

    local link_path
    link_path="${home}/NAS"

    if [[ -L "${link_path}" || -e "${link_path}" ]]; then
        echo "[omamount] Home shortcut already exists: ${link_path}"
        return 0
    fi

    ln -s "${MOUNT_ROOT}" "${link_path}"
    echo "[omamount] Created home shortcut: ${link_path} (NAS shares) -> ${MOUNT_ROOT}"
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

apply_provision() {
    require_config
    require_sudo || return 1

    local count
    count="$(shares_count)"

    echo
    echo "[omamount] This will provision ${count} share(s):"
    echo "  NAS:    //${NAS_IP}/<share>"
    echo "  Mounts: ${MOUNT_ROOT}/<share>"
    echo "  Creds:  ${CREDENTIALS_FILE} (root-only)"
    echo
    read -rp "Continue? [y/N]: " proceed
    if [[ "${proceed,,}" != y && "${proceed,,}" != yes ]]; then
        echo "Aborted. Tip: run --list or --print-fstab to preview."
        return 1
    fi

	echo "[1/7] Dependencies"
	install_packages
	echo "[2/7] Credentials"
	create_credentials
	echo "[3/7] Mount points"
	create_mount_points
	echo "[4/7] /etc/fstab"
	add_shares_to_fstab
	echo "[5/7] systemd integration"
	configure_systemd
	echo "[6/7] Mount now (verification)"
	mount_shares
	echo "[7/7] Verify"
	verify_mounts

    # Optional convenience shortcuts (purely user-level, no system changes).
    if ask_yes_no "Create a home-folder shortcut (~/NAS -> ${MOUNT_ROOT})?" y; then
        add_home_shortcut || true
    fi
    if ask_yes_no "Add a GNOME Files (Nautilus) bookmark for ${MOUNT_ROOT}?" y; then
        add_files_bookmark || true
    fi
    if ask_yes_no "Create a Desktop shortcut to ${MOUNT_ROOT}?" n; then
        add_desktop_shortcut || true
    fi
	echo "Setup complete! NAS shares are configured under ${MOUNT_ROOT}/"
	echo "Tip: With systemd automount, shares mount on first access and won't stall boot if the NAS is offline."
}

needs_wizard() {
    # Return 0 if wizard should run, 1 if not needed.
    require_config

    local credentials_dir
    credentials_dir="$(dirname "${CREDENTIALS_FILE}")"

    if ! have_cmd mount.cifs; then
        return 0
    fi

    if sudo test -e "${credentials_dir}" && ! sudo test -d "${credentials_dir}"; then
        return 0
    fi

    if ! sudo test -f "${CREDENTIALS_FILE}"; then
        return 0
    fi

    if ! (grep -qxF "${FSTAB_BEGIN}" /etc/fstab 2>/dev/null && grep -qxF "${FSTAB_END}" /etc/fstab 2>/dev/null); then
        return 0
    fi

    for share in "${SHARES[@]}"; do
        if [[ ! -d "${MOUNT_ROOT}/${share}" ]]; then
            return 0
        fi
    done

    return 1
}

apply() {
    require_config
    require_sudo || return 1

    if needs_wizard; then
        echo
        echo "[omamount] Preflight found setup gaps — automagically launching --wizard..."
        echo
        wizard
        return $?
    fi

    apply_provision
}

action="${1:-}"
case "${action}" in
    --help|-h|"")
        usage
        exit 0
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
    --wizard)
        wizard
        exit $?
        ;;
    --apply)
        apply
        exit $?
        ;;
    *)
        echo "Unknown argument: ${action}" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac
