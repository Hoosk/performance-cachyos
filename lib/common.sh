#!/usr/bin/env bash
# Common utilities, logging, and system detection helpers for CachyOS/Arch Standby Optimizer

set -euo pipefail

# Global configuration defaults
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-16}"
HIBERNATE_DELAY="${HIBERNATE_DELAY:-2h}"
SLEEP_MODE_PREF="${SLEEP_MODE_PREF:-auto}" # auto | s2idle | deep
CLEAN_CARGO="${CLEAN_CARGO:-0}"

# Managed file paths
UDEV_RULE_FILE="/etc/udev/rules.d/99-standby-optimizer.rules"
SLEEP_DROPIN_DIR="/etc/systemd/sleep.conf.d"
SLEEP_DROPIN_FILE="${SLEEP_DROPIN_DIR}/99-standby-optimizer.conf"
LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN_FILE="${LOGIND_DROPIN_DIR}/99-standby-optimizer.conf"
SWAP_MOUNT_DIR="/swap"
SWAP_FILE_PATH="${SWAP_MOUNT_DIR}/swapfile"
BACKUP_DIR="/var/backups/standby-optimizer"

# Colors
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_BLUE="\033[1;34m"
    C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"
    C_RED="\033[1;31m"
    C_CYAN="\033[1;36m"
else
    C_RESET=""
    C_BOLD=""
    C_BLUE=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_CYAN=""
fi

log_section() {
    printf "\n%b=== %s ===%b\n" "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"
}

log_info() {
    printf "%b[INFO]%b %s\n" "${C_CYAN}" "${C_RESET}" "$1"
}

log_ok() {
    printf "%b[ OK ]%b %s\n" "${C_GREEN}" "${C_RESET}" "$1"
}

log_warn() {
    printf "%b[WARN]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$1"
}

log_err() {
    printf "%b[ERR ]%b %s\n" "${C_RED}" "${C_RESET}" "$1" >&2
}

confirm_action() {
    local prompt="$1"
    if [[ "${ASSUME_YES}" == "1" || "${DRY_RUN}" == "1" ]]; then
        return 0
    fi
    local reply
    read -r -p "${prompt} [y/N]: " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# Execute a command as root (or print it in dry-run mode)
run_priv() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf "%b[DRY-RUN]%b sudo %s\n" "${C_YELLOW}" "${C_RESET}" "$*"
        return 0
    fi
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
    else
        ensure_priv_auth
        if sudo -n true 2>/dev/null; then
            sudo "$@"
        else
            sudo -A "$@"
        fi
    fi
}

# Write content via stdin to a root-owned file safely
write_priv_file() {
    local target="$1"
    local content="$2"
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf "%b[DRY-RUN]%b Write file: %s\n" "${C_YELLOW}" "${C_RESET}" "${target}"
        printf "%s\n" "${content}" | sed 's/^/  | /'
        return 0
    fi
    local parent
    parent="$(dirname "${target}")"
    run_priv mkdir -p "${parent}"
    if [[ "${EUID}" -eq 0 ]]; then
        printf "%s\n" "${content}" > "${target}"
    else
        ensure_priv_auth
        if sudo -n true 2>/dev/null; then
            printf "%s\n" "${content}" | sudo tee "${target}" > /dev/null
        else
            printf "%s\n" "${content}" | sudo -A tee "${target}" > /dev/null
        fi
    fi
}

backup_file() {
    local target="$1"
    if [[ ! -f "${target}" ]]; then
        return 0
    fi
    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"
    local bname
    bname="$(basename "${target}")"
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf "%b[DRY-RUN]%b Backup %s -> %s/%s.%s.bak\n" "${C_YELLOW}" "${C_RESET}" "${target}" "${BACKUP_DIR}" "${bname}" "${stamp}"
        return 0
    fi
    run_priv mkdir -p "${BACKUP_DIR}"
    run_priv cp -a "${target}" "${BACKUP_DIR}/${bname}.${stamp}.bak"
}

get_target_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf "%s" "${SUDO_USER}"
    else
        id -un
    fi
}

get_target_home() {
    local usr
    usr="$(get_target_user)"
    getent passwd "${usr}" | cut -d: -f6
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        printf "%s" "${ID:-unknown}"
    else
        printf "unknown"
    fi
}

detect_bootloader() {
    if [[ -f /etc/default/limine ]] || command -v limine-update >/dev/null 2>&1; then
        printf "limine"
    elif [[ -d /boot/loader/entries ]] || [[ -f /boot/loader/loader.conf ]]; then
        printf "systemd-boot"
    elif [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null 2>&1; then
        printf "grub"
    else
        printf "unknown"
    fi
}

detect_root_fstype() {
    findmnt -n -o FSTYPE / 2>/dev/null || printf "unknown"
}

detect_root_source() {
    findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//'
}

detect_root_uuid() {
    local src uuid
    src="$(detect_root_source)"
    uuid="$(findmnt -n -o UUID / 2>/dev/null | head -n1 || true)"
    if [[ -z "${uuid}" && -n "${src}" ]]; then
        uuid="$(lsblk -no UUID "${src}" 2>/dev/null | head -n1 || true)"
    fi
    if [[ -z "${uuid}" && -n "${src}" ]]; then
        uuid="$(blkid -s UUID -o value "${src}" 2>/dev/null || true)"
    fi
    printf "%s" "${uuid}"
}
