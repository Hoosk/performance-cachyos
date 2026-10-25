#!/usr/bin/env bash
# Swapfile & Hibernation Storage Provisioning Module (Btrfs @swap subvolume & ext4 support)

run_swap_hibernate() {
    log_section "Disk Swapfile Setup for Hibernation (0W Standby)"

    local root_fs root_src root_uuid
    root_fs="$(detect_root_fstype)"
    root_src="$(detect_root_source)"
    root_uuid="$(detect_root_uuid)"

    # Check available free space in GiB
    local avail_kb avail_gb required_gb
    avail_kb="$(df --output=avail / | tail -n1 | xargs)"
    avail_gb=$(( avail_kb / 1048576 ))
    required_gb=$(( SWAP_SIZE_GB + 5 ))

    if [[ "${avail_gb}" -lt "${required_gb}" ]]; then
        log_err "Insufficient free disk space on /: ${avail_gb} GiB available, need at least ${required_gb} GiB (for ${SWAP_SIZE_GB} GiB swapfile + 5 GiB buffer)."
        log_err "Run with '--clean' or '--clean-cargo' first to free up disk space."
        return 1
    fi

    log_info "Root filesystem: ${root_fs} on ${root_src} (UUID=${root_uuid}), Free space: ${avail_gb} GiB"

    backup_file /etc/fstab

    if [[ "${root_fs}" == "btrfs" ]]; then
        setup_btrfs_swapfile "${root_src}" "${root_uuid}"
    elif [[ "${root_fs}" == "ext4" || "${root_fs}" == "xfs" ]]; then
        setup_standard_swapfile
    else
        log_err "Unsupported root filesystem '${root_fs}' for automatic swapfile provisioning."
        return 1
    fi

    # Ensure /swap/swapfile entry in /etc/fstab with pri=0 (below zram0 pri=100)
    if ! grep -qE "^${SWAP_FILE_PATH}[[:space:]]" /etc/fstab 2>/dev/null; then
        log_info "Adding ${SWAP_FILE_PATH} (pri=0) to /etc/fstab..."
        append_priv_file /etc/fstab "${SWAP_FILE_PATH} none swap defaults,pri=0 0 0"
    else
        log_info "${SWAP_FILE_PATH} is already present in /etc/fstab."
    fi

    # Activate swapfile with priority 0 if not already active
    if ! grep -q "^${SWAP_FILE_PATH}[[:space:]]" /proc/swaps 2>/dev/null; then
        log_info "Activating swapfile ${SWAP_FILE_PATH} with priority 0 (zram remains primary at priority 100)..."
        run_priv swapon -p 0 "${SWAP_FILE_PATH}"
    else
        log_info "Swapfile ${SWAP_FILE_PATH} is already active."
    fi

    log_ok "Swapfile configured and active for hibernation:"
    cat /proc/swaps | sed 's/^/  /'
}

setup_btrfs_swapfile() {
    local root_src="$1"
    local root_uuid="$2"
    local tmp_mnt="/run/btrfs-standby-root"

    log_info "Preparing dedicated Btrfs '@swap' subvolume (excluded from root snapshots)..."
    run_priv mkdir -p "${tmp_mnt}" "${SWAP_MOUNT_DIR}"

    if [[ "${DRY_RUN}" != "1" ]]; then
        run_priv mount -o subvolid=5 "${root_src}" "${tmp_mnt}"
        if [[ ! -d "${tmp_mnt}/@swap" ]]; then
            log_info "Creating Btrfs subvolume @swap..."
            run_priv btrfs subvolume create "${tmp_mnt}/@swap"
        else
            log_info "Btrfs subvolume @swap already exists."
        fi
        run_priv umount "${tmp_mnt}"
        run_priv rmdir "${tmp_mnt}" 2>/dev/null || true
    else
        printf "%b[DRY-RUN]%b Mount %s (subvolid=5) and create @swap subvolume if missing\n" "${C_YELLOW}" "${C_RESET}" "${root_src}"
    fi

    # Add /swap subvolume mount to /etc/fstab if missing
    if ! grep -qE "[[:space:]]${SWAP_MOUNT_DIR}[[:space:]]+btrfs" /etc/fstab 2>/dev/null; then
        log_info "Adding /swap subvolume mount to /etc/fstab..."
        local fstab_line="UUID=${root_uuid} ${SWAP_MOUNT_DIR} btrfs subvol=/@swap,defaults,noatime 0 0"
        append_priv_file /etc/fstab "${fstab_line}"
    fi

    if ! mountpoint -q "${SWAP_MOUNT_DIR}" 2>/dev/null; then
        log_info "Mounting ${SWAP_MOUNT_DIR}..."
        run_priv mount "${SWAP_MOUNT_DIR}"
        run_priv systemctl daemon-reload
    fi

    if [[ ! -f "${SWAP_FILE_PATH}" ]]; then
        log_info "Creating ${SWAP_SIZE_GB} GiB Btrfs swapfile at ${SWAP_FILE_PATH} (NoCoW + uncompressed)..."
        run_priv btrfs filesystem mkswapfile --size "${SWAP_SIZE_GB}g" "${SWAP_FILE_PATH}"
    else
        log_info "Swapfile ${SWAP_FILE_PATH} already exists."
    fi
}

setup_standard_swapfile() {
    run_priv mkdir -p "${SWAP_MOUNT_DIR}"
    if [[ ! -f "${SWAP_FILE_PATH}" ]]; then
        log_info "Creating ${SWAP_SIZE_GB} GiB swapfile at ${SWAP_FILE_PATH}..."
        run_priv dd if=/dev/zero of="${SWAP_FILE_PATH}" bs=1M count=$(( SWAP_SIZE_GB * 1024 )) status=progress
        run_priv chmod 0600 "${SWAP_FILE_PATH}"
        run_priv mkswap "${SWAP_FILE_PATH}"
    else
        log_info "Swapfile ${SWAP_FILE_PATH} already exists."
    fi
}
