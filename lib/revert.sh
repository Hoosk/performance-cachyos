#!/usr/bin/env bash
# Rollback / Revert Module for Standby Optimizer

run_revert() {
    log_section "Reverting Standby Optimizer Configurations"

    if [[ -f "${UDEV_RULE_FILE}" ]]; then
        log_info "Removing ${UDEV_RULE_FILE}..."
        run_priv rm -f "${UDEV_RULE_FILE}"
        run_priv udevadm control --reload-rules
        run_priv udevadm trigger
        log_ok "Removed udev standby rules."
    fi

    if [[ -f "${SLEEP_DROPIN_FILE}" ]]; then
        log_info "Removing ${SLEEP_DROPIN_FILE}..."
        run_priv rm -f "${SLEEP_DROPIN_FILE}"
        log_ok "Removed systemd-sleep drop-in."
    fi

    if [[ -f "${LOGIND_DROPIN_FILE}" ]]; then
        log_info "Removing ${LOGIND_DROPIN_FILE}..."
        run_priv rm -f "${LOGIND_DROPIN_FILE}"
        log_ok "Removed systemd-logind drop-in."
    fi

    run_priv systemctl daemon-reload

    if grep -q "^${SWAP_FILE_PATH}[[:space:]]" /proc/swaps 2>/dev/null; then
        log_info "Deactivating swapfile ${SWAP_FILE_PATH}..."
        run_priv swapoff "${SWAP_FILE_PATH}"
    fi

    if [[ -f /etc/fstab ]] && grep -q "${SWAP_MOUNT_DIR}" /etc/fstab 2>/dev/null; then
        log_info "Removing ${SWAP_MOUNT_DIR} entries from /etc/fstab..."
        backup_file /etc/fstab
        local cleaned_fstab
        cleaned_fstab="$(grep -vE "${SWAP_MOUNT_DIR}" /etc/fstab)"
        write_priv_file /etc/fstab "${cleaned_fstab}"
    fi

    if [[ -f /etc/default/limine ]] && grep -qE "pcie_aspm\.policy=|mem_sleep_default=" /etc/default/limine 2>/dev/null; then
        log_info "Cleaning kernel parameters from /etc/default/limine..."
        backup_file /etc/default/limine
        local cleaned_limine
        cleaned_limine="$(sed -E 's/ ?pcie_aspm\.policy=[^" ]+//g; s/ ?mem_sleep_default=[^" ]+//g' /etc/default/limine)"
        write_priv_file /etc/default/limine "${cleaned_limine}"
        if command -v limine-update >/dev/null 2>&1; then
            run_priv limine-update
        fi
    fi

    log_ok "All standby-optimizer changes have been reverted."
}
