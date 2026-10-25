#!/usr/bin/env bash
# Disk & Package Cache Cleanup Module (Pacman, Paru/Yay, optional Rust Cargo targets)

run_cleanup() {
    log_section "Disk & Cache Cleanup"
    log_info "Disk usage before cleanup:"
    df -h / | sed 's/^/  /'

    # 1. Clean Pacman package cache (keep only 1 latest version of installed packages, 0 of uninstalled)
    if command -v paccache >/dev/null 2>&1; then
        log_info "Cleaning pacman cache with paccache (keeping 1 installed version, 0 uninstalled)..."
        run_priv paccache -rk1
        run_priv paccache -ruk0
        log_ok "Pacman package cache cleaned."
    elif command -v pacman >/dev/null 2>&1; then
        log_info "paccache not found; running 'pacman -Sc --noconfirm'..."
        run_priv pacman -Sc --noconfirm
        log_ok "Pacman cache cleaned."
    fi

    # 2. Clean Paru / Yay AUR build caches for the target user
    local user_home target_user
    user_home="$(get_target_home)"
    target_user="$(get_target_user)"

    if [[ -d "${user_home}/.cache/paru/clone" ]]; then
        local paru_size
        paru_size="$(du -sh "${user_home}/.cache/paru/clone" 2>/dev/null | cut -f1 || printf "0")"
        log_info "Cleaning paru clone cache (${paru_size}) at ${user_home}/.cache/paru/clone..."
        if [[ "${DRY_RUN}" == "1" ]]; then
            printf "%b[DRY-RUN]%b rm -rf %s/.cache/paru/clone/*\n" "${C_YELLOW}" "${C_RESET}" "${user_home}"
        else
            rm -rf "${user_home}/.cache/paru/clone/"* 2>/dev/null || true
        fi
        log_ok "Paru AUR cache cleaned."
    fi

    if [[ -d "${user_home}/.cache/yay" ]]; then
        local yay_size
        yay_size="$(du -sh "${user_home}/.cache/yay" 2>/dev/null | cut -f1 || printf "0")"
        log_info "Cleaning yay cache (${yay_size}) at ${user_home}/.cache/yay..."
        if [[ "${DRY_RUN}" == "1" ]]; then
            printf "%b[DRY-RUN]%b rm -rf %s/.cache/yay/*\n" "${C_YELLOW}" "${C_RESET}" "${user_home}"
        else
            rm -rf "${user_home}/.cache/yay/"* 2>/dev/null || true
        fi
        log_ok "Yay AUR cache cleaned."
    fi

    # 3. Optional Rust Cargo target directory cleanup
    if [[ "${CLEAN_CARGO}" == "1" ]] && command -v cargo >/dev/null 2>&1; then
        log_info "Scanning ${user_home} for Rust Cargo.toml projects with large target/ directories..."
        while IFS= read -r -d '' cargo_toml; do
            local proj_dir target_dir
            proj_dir="$(dirname "${cargo_toml}")"
            target_dir="${proj_dir}/target"
            if [[ -d "${target_dir}" ]]; then
                local tsize
                tsize="$(du -sh "${target_dir}" 2>/dev/null | cut -f1 || printf "0")"
                log_info "Running 'cargo clean' in ${proj_dir} (target size: ${tsize})..."
                if [[ "${DRY_RUN}" == "1" ]]; then
                    printf "%b[DRY-RUN]%b (cd %s && cargo clean)\n" "${C_YELLOW}" "${C_RESET}" "${proj_dir}"
                else
                    sudo -u "${target_user}" bash -c "cd \"${proj_dir}\" && cargo clean" || true
                fi
            fi
        done < <(find "${user_home}" -maxdepth 5 -name "Cargo.toml" -not -path "*/.*/*" -print0 2>/dev/null)
        log_ok "Rust Cargo target cleanup finished."
    fi

    log_info "Disk usage after cleanup:"
    df -h / | sed 's/^/  /'
}
