#!/usr/bin/env bash
# System Standby, Power Management & Disk Diagnostic Module

run_analyze() {
    log_section "1. Hardware & System Summary"
    local vendor product cpu kernel distro bootloader root_fs
    vendor="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || printf "Unknown")"
    product="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || printf "Unknown")"
    cpu="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || printf "Unknown")"
    kernel="$(uname -r)"
    distro="$(detect_distro)"
    bootloader="$(detect_bootloader)"
    root_fs="$(detect_root_fstype)"

    log_info "Device      : ${vendor} ${product}"
    log_info "CPU         : ${cpu}"
    log_info "Distro      : ${distro} (Kernel: ${kernel})"
    log_info "Bootloader  : ${bootloader} | Root FS: ${root_fs}"
    log_info "Cmdline     : $(cat /proc/cmdline 2>/dev/null)"

    if [[ -d /sys/devices/platform/lg-laptop ]]; then
        local care_limit
        care_limit="$(cat /sys/devices/platform/lg-laptop/battery_care_limit 2>/dev/null || printf "N/A")"
        log_info "LG Laptop   : detected (battery_care_limit=${care_limit}%)"
    fi

    log_section "2. Sleep Mode & Hardware Residency Telemetry"
    local mem_sleep state
    mem_sleep="$(cat /sys/power/mem_sleep 2>/dev/null || printf "unknown")"
    state="$(cat /sys/power/state 2>/dev/null || printf "unknown")"
    log_info "Available sleep modes (/sys/power/mem_sleep): ${mem_sleep}"
    log_info "Available power states (/sys/power/state)   : ${state}"

    if [[ "${mem_sleep}" == *"[s2idle]"* && "${mem_sleep}" == *"deep"* ]]; then
        log_warn "System is currently using [s2idle] (Modern Standby), although hardware S3 (deep) is also advertised by BIOS."
    fi

    local succ fail last_hw total_hw sys_res cpu_res
    succ="$(cat /sys/power/suspend_stats/success 2>/dev/null || printf "0")"
    fail="$(cat /sys/power/suspend_stats/fail 2>/dev/null || printf "0")"
    last_hw="$(cat /sys/power/suspend_stats/last_hw_sleep 2>/dev/null || printf "0")"
    total_hw="$(cat /sys/power/suspend_stats/total_hw_sleep 2>/dev/null || printf "0")"
    sys_res="$(cat /sys/devices/system/cpu/cpuidle/low_power_idle_system_residency_us 2>/dev/null || printf "0")"
    cpu_res="$(cat /sys/devices/system/cpu/cpuidle/low_power_idle_cpu_residency_us 2>/dev/null || printf "0")"

    local last_hw_min total_hw_min sys_res_min cpu_res_min
    last_hw_min=$(( last_hw / 60000000 ))
    total_hw_min=$(( total_hw / 60000000 ))
    sys_res_min=$(( sys_res / 60000000 ))
    cpu_res_min=$(( cpu_res / 60000000 ))

    log_info "Suspend cycles since boot : ${succ} successful, ${fail} failed"
    log_info "Last HW sleep residency   : ${last_hw_min} min (${last_hw} us)"
    log_info "Total HW sleep residency  : ${total_hw_min} min (${total_hw} us)"
    log_info "S0ix System residency     : ${sys_res_min} min | CPU deep residency: ${cpu_res_min} min"

    log_section "3. Wakeup Sources & Spurious Interrupts"
    log_info "Top active kernel wakeup sources:"
    for wf in /sys/class/wakeup/wakeup*; do
        [[ -d "${wf}" ]] || continue
        local wname wact
        wname="$(cat "${wf}/name" 2>/dev/null || printf "unknown")"
        wact="$(cat "${wf}/active_count" 2>/dev/null || printf "0")"
        if [[ "${wact}" -gt 10 ]]; then
            printf "  - %-28s active_count=%s\n" "${wname}" "${wact}"
        fi
    done | sort -t= -k2 -nr | head -n 10

    log_info "I2C / PCI devices currently allowed to wake the system:"
    for wpath in /sys/bus/i2c/devices/*/power/wakeup /sys/bus/pci/devices/*/power/wakeup; do
        [[ -f "${wpath}" ]] || continue
        if [[ "$(cat "${wpath}" 2>/dev/null)" == "enabled" ]]; then
            local dev_dir dev_id dev_desc
            dev_dir="$(dirname "$(dirname "${wpath}")")"
            dev_id="$(basename "${dev_dir}")"
            if [[ "${wpath}" == *"/pci/"* ]]; then
                dev_desc="$(lspci -s "${dev_id}" 2>/dev/null || printf "PCI device")"
            else
                dev_desc="I2C HID/Touchpad ($(cat "${dev_dir}/name" 2>/dev/null || printf "i2c"))"
            fi
            log_warn "Wakeup ENABLED on ${dev_id}: ${dev_desc}"
        fi
    done

    log_section "4. PCIe ASPM, Runtime PM & NVMe Power State"
    local aspm_policy
    aspm_policy="$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || printf "unknown")"
    log_info "PCIe ASPM policy: ${aspm_policy}"
    if [[ "${aspm_policy}" == *"[default]"* ]]; then
        log_warn "PCIe ASPM is set to [default]. Enabling 'powersupersave' or 'powersave' helps NVMe/Wi-Fi enter L1.2 for S0ix."
    else
        log_ok "PCIe ASPM policy is tuned."
    fi

    local pci_on_count=0
    for ctrl in /sys/bus/pci/devices/*/power/control; do
        [[ -f "${ctrl}" ]] || continue
        if [[ "$(cat "${ctrl}" 2>/dev/null)" == "on" ]]; then
            pci_on_count=$(( pci_on_count + 1 ))
        fi
    done
    log_info "PCI devices with Runtime PM forced 'on' (disabled): ${pci_on_count}"

    for nv in /sys/class/nvme/nvme*; do
        [[ -d "${nv}" ]] || continue
        local nv_name nv_model nv_d3
        nv_name="$(basename "${nv}")"
        nv_model="$(cat "${nv}/model" 2>/dev/null | xargs || printf "Unknown")"
        nv_d3="$(cat "${nv}/device/d3cold_allowed" 2>/dev/null || printf "?")"
        log_info "NVMe ${nv_name}: ${nv_model} (d3cold_allowed=${nv_d3})"
    done

    log_section "5. Swap, ZRAM & Hibernation Readiness"
    local swaps_disk=0
    while read -r fname ftype fsize fused fprio; do
        [[ "${fname}" == "Filename" || -z "${fname}" ]] && continue
        log_info "Swap active: ${fname} (${ftype}, size=$((fsize / 1024)) MiB, prio=${fprio})"
        if [[ "${fname}" != *"/zram"* ]]; then
            swaps_disk=1
        fi
    done < /proc/swaps

    local img_size_bytes img_size_gb
    img_size_bytes="$(cat /sys/power/image_size 2>/dev/null || printf "0")"
    img_size_gb=$(( (img_size_bytes + 1073741823) / 1073741824 ))
    log_info "Kernel hibernation target image_size: ~${img_size_gb} GiB (${img_size_bytes} bytes)"

    if [[ "${swaps_disk}" -eq 0 ]]; then
        log_warn "No disk-backed swap detected (only zram). System CANNOT hibernate or use suspend-then-hibernate."
    else
        log_ok "Disk-backed swap is present for hibernation."
    fi

    log_section "6. Disk Space & Cache Analysis"
    df -h / | sed 's/^/  /'
    local pkg_cache="/var/cache/pacman/pkg"
    if [[ -d "${pkg_cache}" ]]; then
        log_info "Pacman cache (${pkg_cache}): $(du -sh "${pkg_cache}" 2>/dev/null | cut -f1)"
    fi
    local user_home
    user_home="$(get_target_home)"
    if [[ -d "${user_home}/.cache/paru/clone" ]]; then
        log_info "Paru AUR cache (${user_home}/.cache/paru/clone): $(du -sh "${user_home}/.cache/paru/clone" 2>/dev/null | cut -f1)"
    fi
    if [[ -d "${user_home}/.cache/yay" ]]; then
        log_info "Yay AUR cache (${user_home}/.cache/yay): $(du -sh "${user_home}/.cache/yay" 2>/dev/null | cut -f1)"
    fi
}
