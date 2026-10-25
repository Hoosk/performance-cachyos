#!/usr/bin/env bash
# Bootloader & Initramfs Kernel Parameter Configuration Module (Limine, GRUB, systemd-boot)

run_bootloader() {
    log_section "Bootloader & Kernel Command-Line Optimization"

    # 1. Verify initramfs (/etc/mkinitcpio.conf) hibernation support
    if [[ -f /etc/mkinitcpio.conf ]]; then
        local hooks_line
        hooks_line="$(grep -E '^HOOKS=' /etc/mkinitcpio.conf 2>/dev/null || printf "")"
        if [[ "${hooks_line}" == *"systemd"* ]]; then
            log_ok "mkinitcpio uses the 'systemd' hook (native EFI HibernateLocation resume supported)."
        elif [[ "${hooks_line}" == *"resume"* ]]; then
            log_ok "mkinitcpio includes the 'resume' hook."
        else
            log_warn "mkinitcpio HOOKS (${hooks_line}) does not contain 'systemd' or 'resume'. Adding 'resume' hook is recommended for hibernation."
        fi
    fi

    # 2. Build desired kernel parameters list
    local params_to_add=("pcie_aspm.policy=powersupersave")
    if [[ "${SLEEP_MODE_PREF}" == "deep" ]]; then
        params_to_add+=("mem_sleep_default=deep")
    elif [[ "${SLEEP_MODE_PREF}" == "s2idle" ]]; then
        params_to_add+=("mem_sleep_default=s2idle")
    fi

    local bootloader
    bootloader="$(detect_bootloader)"
    log_info "Detected bootloader: ${bootloader}"

    case "${bootloader}" in
        limine)
            update_limine_cmdline "${params_to_add[@]}"
            ;;
        grub)
            update_grub_cmdline "${params_to_add[@]}"
            ;;
        systemd-boot)
            update_systemd_boot_cmdline "${params_to_add[@]}"
            ;;
        *)
            log_warn "Unknown bootloader. Add these kernel parameters manually: ${params_to_add[*]}"
            ;;
    esac
}

update_limine_cmdline() {
    local limine_file="/etc/default/limine"
    if [[ ! -f "${limine_file}" ]]; then
        log_err "${limine_file} not found."
        return 1
    fi

    backup_file "${limine_file}"
    local current_content new_content cmdline_line
    current_content="$(cat "${limine_file}")"
    cmdline_line="$(grep -E '^KERNEL_CMDLINE\[default\]\+=' "${limine_file}" | head -n1 || printf "")"

    if [[ -z "${cmdline_line}" ]]; then
        log_err "Could not find KERNEL_CMDLINE[default]+= in ${limine_file}."
        return 1
    fi

    local updated_line="${cmdline_line}"
    # Strip existing pcie_aspm.policy or mem_sleep_default before re-adding cleanly
    updated_line="$(printf "%s" "${updated_line}" | sed -E 's/ ?pcie_aspm\.policy=[^" ]+//g; s/ ?mem_sleep_default=[^" ]+//g')"

    for param in "$@"; do
        updated_line="$(printf "%s" "${updated_line}" | sed -E "s/\"$/ ${param}\"/")"
    done

    new_content="$(awk -v repl="${updated_line}" '
        /^KERNEL_CMDLINE\[default\]\+=/ && !done { print repl; done=1; next }
        { print }
    ' "${limine_file}")"
    write_priv_file "${limine_file}" "${new_content}"
    log_ok "Updated ${limine_file}: ${updated_line}"

    if command -v limine-update >/dev/null 2>&1; then
        log_info "Running limine-update..."
        run_priv limine-update
        log_ok "Limine boot entries updated."
    fi
}

update_grub_cmdline() {
    local grub_file="/etc/default/grub"
    backup_file "${grub_file}"
    local current_content cmdline_line updated_line new_content
    current_content="$(cat "${grub_file}")"
    cmdline_line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${grub_file}" | head -n1 || printf "")"

    if [[ -z "${cmdline_line}" ]]; then
        log_err "Could not find GRUB_CMDLINE_LINUX_DEFAULT in ${grub_file}."
        return 1
    fi

    updated_line="$(printf "%s" "${cmdline_line}" | sed -E 's/ ?pcie_aspm\.policy=[^"'\'' ]+//g; s/ ?mem_sleep_default=[^"'\'' ]+//g')"
    for param in "$@"; do
        updated_line="$(printf "%s" "${updated_line}" | sed -E "s/([\"'])$/ ${param}\1/")"
    done

    new_content="$(awk -v repl="${updated_line}" '
        /^GRUB_CMDLINE_LINUX_DEFAULT=/ && !done { print repl; done=1; next }
        { print }
    ' "${grub_file}")"
    write_priv_file "${grub_file}" "${new_content}"
    log_ok "Updated ${grub_file}: ${updated_line}"

    log_info "Regenerating GRUB configuration..."
    run_priv grub-mkconfig -o /boot/grub/grub.cfg
    log_ok "GRUB configuration updated."
}

update_systemd_boot_cmdline() {
    log_info "Updating systemd-boot entries under /boot/loader/entries/..."
    for entry in /boot/loader/entries/*.conf; do
        [[ -f "${entry}" ]] || continue
        backup_file "${entry}"
        local content opts_line updated_opts new_content
        content="$(cat "${entry}")"
        opts_line="$(grep -E '^options[[:space:]]+' "${entry}" | head -n1 || printf "")"
        [[ -z "${opts_line}" ]] && continue
        updated_opts="$(printf "%s" "${opts_line}" | sed -E 's/ ?pcie_aspm\.policy=[^ ]+//g; s/ ?mem_sleep_default=[^ ]+//g')"
        for param in "$@"; do
            updated_opts+=" ${param}"
        done
        new_content="$(awk -v repl="${updated_opts}" '
            /^options[[:space:]]+/ && !done { print repl; done=1; next }
            { print }
        ' "${entry}")"
        write_priv_file "${entry}" "${new_content}"
        log_ok "Updated ${entry}"
    done
}
