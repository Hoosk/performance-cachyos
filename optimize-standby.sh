#!/usr/bin/env bash
# ==============================================================================
# CachyOS / Arch Linux Laptop Standby & Power Optimizer
# Modular CLI tool to diagnose and fix s2idle/S3 battery drain, spurious wakeups,
# PCIe ASPM, and configure 0W suspend-then-hibernate.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load modules
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=lib/analyze.sh
source "${SCRIPT_DIR}/lib/analyze.sh"
# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"
# shellcheck source=lib/udev_power.sh
source "${SCRIPT_DIR}/lib/udev_power.sh"
# shellcheck source=lib/swap_hibernate.sh
source "${SCRIPT_DIR}/lib/swap_hibernate.sh"
# shellcheck source=lib/systemd_sleep.sh
source "${SCRIPT_DIR}/lib/systemd_sleep.sh"
# shellcheck source=lib/bootloader.sh
source "${SCRIPT_DIR}/lib/bootloader.sh"
# shellcheck source=lib/revert.sh
source "${SCRIPT_DIR}/lib/revert.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [ACTIONS] [OPTIONS]

Modular CachyOS / Arch Linux Laptop Standby & Power Optimizer.

Actions:
  --analyze              Run full hardware, sleep residency, wakeup & disk diagnostic
  --all                  Run full optimization pipeline (analyze + clean + udev + swap + systemd + bootloader)
  --clean                Clean pacman cache (paccache) and AUR caches (paru/yay)
  --clean-cargo          Also run 'cargo clean' on Rust projects under user home during --clean
  --udev                 Generate & apply udev rules (disable spurious I2C/PCIe wakeups, enable Runtime PM)
  --swap                 Create & enable disk swapfile (Btrfs @swap subvol or ext4, pri=0 below zram)
  --systemd              Configure systemd-logind & systemd-sleep drop-ins (suspend-then-hibernate)
  --bootloader           Configure PCIe ASPM & sleep kernel parameters (Limine / GRUB / systemd-boot)
  --test-deep            Run a safe 15-second RTC alarm test of ACPI S3 (deep) sleep mode
  --setup-keyring        Save/update sudo password in desktop keyring (libsecret / KWallet)
  --clear-keyring        Remove saved sudo password from desktop keyring
  --revert               Revert all configurations, udev rules, drop-ins, and fstab entries

Options:
  --sleep-mode <mode>    Target sleep mode: s2idle | deep | auto (default: ${SLEEP_MODE_PREF})
  --hibernate-delay <t>  Time in suspend before hibernating to disk (default: ${HIBERNATE_DELAY})
  --swap-size <GB>       Swapfile size in GiB for hibernation (default: ${SWAP_SIZE_GB})
  --dry-run              Preview all commands and file changes without modifying the system
  -y, --yes              Non-interactive mode (assume yes to prompts)
  -h, --help             Show this help message

Examples:
  ./$(basename "$0") --setup-keyring
  ./$(basename "$0") --analyze
  ./$(basename "$0") --all --dry-run
  ./$(basename "$0") --all --sleep-mode s2idle --hibernate-delay 2h -y
  ./$(basename "$0") --test-deep
EOF
}

interactive_menu() {
    while true; do
        printf "\n%b=============================================================%b\n" "${C_BOLD}${C_BLUE}" "${C_RESET}"
        printf "%b  CachyOS / Arch Linux Standby & Power Optimizer             %b\n" "${C_BOLD}" "${C_RESET}"
        printf "%b=============================================================%b\n" "${C_BOLD}${C_BLUE}" "${C_RESET}"
        printf "  1) Analyze system (Sleep residency, wakeups, ASPM, swap, disk)\n"
        printf "  2) Apply ALL optimizations (Clean + Udev + Swap + Systemd + Bootloader)\n"
        printf "  3) Clean disk caches only (Pacman, Paru/Yay, optional Cargo)\n"
        printf "  4) Optimize Standby Wakeups & PCI Runtime PM (udev rules)\n"
        printf "  5) Setup Disk Swapfile (@swap Btrfs / ext4, pri=0) for Hibernation\n"
        printf "  6) Configure systemd suspend-then-hibernate & Sleep Mode\n"
        printf "  7) Configure Bootloader PCIe ASPM (Limine / GRUB / systemd-boot)\n"
        printf "  8) Test Hardware S3 (deep) sleep for 15 seconds (rtcwake)\n"
        printf "  9) Revert all changes made by this tool\n"
        printf " 10) Setup / Update Desktop Keyring integration (passwordless sudo)\n"
        printf " 11) Clear saved credentials from Desktop Keyring\n"
        printf "  0) Exit\n"
        printf -- "-------------------------------------------------------------\n"
        local choice=""
        read -r -p "Select an option [0-11]: " choice || exit 0
        case "${choice}" in
            1) run_analyze || log_warn "Analysis finished with warnings." ;;
            2)
                run_analyze || true
                if confirm_action "Proceed with full optimization pipeline?"; then
                    if run_cleanup && run_udev_power && run_swap_hibernate && run_systemd_sleep && run_bootloader; then
                        log_section "Optimization Complete!"
                        log_ok "All standby optimizations have been applied."
                    else
                        log_warn "Optimization pipeline stopped due to an error."
                    fi
                fi
                ;;
            3) run_cleanup || log_warn "Cleanup did not complete." ;;
            4) run_udev_power || log_warn "Udev power optimization did not complete." ;;
            5) run_swap_hibernate || log_warn "Swapfile setup did not complete." ;;
            6) run_systemd_sleep || log_warn "Systemd configuration did not complete." ;;
            7) run_bootloader || log_warn "Bootloader update did not complete." ;;
            8) run_test_deep_sleep || log_warn "S3 deep sleep test did not complete." ;;
            9)
                if confirm_action "Are you sure you want to revert all standby-optimizer changes?"; then
                    run_revert || log_warn "Revert did not complete."
                fi
                ;;
            10) run_setup_keyring || log_warn "Keyring setup did not complete." ;;
            11) run_clear_keyring || log_warn "Keyring clear did not complete." ;;
            0|q|Q) exit 0 ;;
            *) log_warn "Invalid option: ${choice}" ;;
        esac
    done
}

main() {
    if [[ $# -eq 0 ]]; then
        interactive_menu
        exit 0
    fi

    local do_analyze=0
    local do_clean=0
    local do_udev=0
    local do_swap=0
    local do_systemd=0
    local do_bootloader=0
    local do_test_deep=0
    local do_setup_keyring=0
    local do_clear_keyring=0
    local do_revert=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --analyze)
                do_analyze=1
                shift
                ;;
            --all)
                do_analyze=1
                do_clean=1
                do_udev=1
                do_swap=1
                do_systemd=1
                do_bootloader=1
                shift
                ;;
            --clean)
                do_clean=1
                shift
                ;;
            --clean-cargo)
                do_clean=1
                CLEAN_CARGO=1
                shift
                ;;
            --udev)
                do_udev=1
                shift
                ;;
            --swap)
                do_swap=1
                shift
                ;;
            --systemd)
                do_systemd=1
                shift
                ;;
            --bootloader)
                do_bootloader=1
                shift
                ;;
            --test-deep)
                do_test_deep=1
                shift
                ;;
            --setup-keyring)
                do_setup_keyring=1
                shift
                ;;
            --clear-keyring)
                do_clear_keyring=1
                shift
                ;;
            --revert)
                do_revert=1
                shift
                ;;
            --sleep-mode)
                SLEEP_MODE_PREF="${2:-auto}"
                if [[ ! "${SLEEP_MODE_PREF}" =~ ^(auto|s2idle|deep)$ ]]; then
                    log_err "Invalid --sleep-mode '${SLEEP_MODE_PREF}'. Must be: auto | s2idle | deep"
                    exit 1
                fi
                shift 2
                ;;
            --hibernate-delay)
                HIBERNATE_DELAY="${2:-2h}"
                shift 2
                ;;
            --swap-size)
                SWAP_SIZE_GB="${2:-16}"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_err "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ "${do_clear_keyring}" -eq 1 ]]; then
        run_clear_keyring
        exit 0
    fi
    if [[ "${do_setup_keyring}" -eq 1 ]]; then
        run_setup_keyring
    fi
    if [[ "${do_revert}" -eq 1 ]]; then
        run_revert
        exit 0
    fi

    if [[ "${do_analyze}" -eq 1 ]]; then
        run_analyze
    fi
    if [[ "${do_clean}" -eq 1 ]]; then
        run_cleanup
    fi
    if [[ "${do_udev}" -eq 1 ]]; then
        run_udev_power
    fi
    if [[ "${do_swap}" -eq 1 ]]; then
        run_swap_hibernate
    fi
    if [[ "${do_systemd}" -eq 1 ]]; then
        run_systemd_sleep
    fi
    if [[ "${do_bootloader}" -eq 1 ]]; then
        run_bootloader
    fi
    if [[ "${do_test_deep}" -eq 1 ]]; then
        run_test_deep_sleep
    fi
}

main "$@"
