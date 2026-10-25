#!/usr/bin/env bash
# Desktop Keyring Authentication Module (libsecret / GNOME Keyring / KWallet + SUDO_ASKPASS)

KEYRING_APP="standby-optimizer"
PRIV_AUTH_READY="${PRIV_AUTH_READY:-0}"

detect_keyring_backend() {
    if command -v secret-tool >/dev/null 2>&1; then
        printf "libsecret"
    elif command -v kwallet-query >/dev/null 2>&1; then
        printf "kwallet"
    else
        printf "none"
    fi
}

keyring_has_secret() {
    local usr backend
    usr="$(get_target_user)"
    backend="$(detect_keyring_backend)"
    case "${backend}" in
        libsecret)
            secret-tool lookup application "${KEYRING_APP}" username "${usr}" >/dev/null 2>&1
            ;;
        kwallet)
            local val
            val="$(kwallet-query kdewallet -f "${KEYRING_APP}" -r "${usr}" 2>/dev/null || true)"
            [[ -n "${val}" && "${val}" != "Failed"* ]]
            ;;
        *)
            return 1
            ;;
    esac
}

run_setup_keyring() {
    log_section "System Keyring Integration Setup"
    local usr backend
    usr="$(get_target_user)"
    backend="$(detect_keyring_backend)"

    if [[ "${backend}" == "none" ]]; then
        log_err "No supported keyring CLI found. Install 'libsecret' (secret-tool) or 'kwallet'."
        return 1
    fi

    log_info "Keyring backend : ${backend} (user: ${usr})"
    local pw=""
    read -r -s -p "Enter sudo password for '${usr}' to store in keyring: " pw
    printf "\n"

    if [[ -z "${pw}" ]]; then
        log_err "Password cannot be empty."
        return 1
    fi

    log_info "Verifying sudo credentials..."
    if ! printf "%s\n" "${pw}" | sudo -k -S -p "" true 2>/dev/null; then
        pw=""
        log_err "Invalid sudo password. Nothing was stored in the keyring."
        return 1
    fi

    case "${backend}" in
        libsecret)
            printf "%s" "${pw}" | secret-tool store \
                --label="Standby Optimizer sudo (${usr})" \
                application "${KEYRING_APP}" \
                username "${usr}"
            ;;
        kwallet)
            printf "%s" "${pw}" | kwallet-query kdewallet -f "${KEYRING_APP}" -w "${usr}" >/dev/null
            ;;
    esac
    pw=""

    export SUDO_KEYRING_USER="${usr}"
    export SUDO_ASKPASS="${SCRIPT_DIR}/lib/askpass-keyring.sh"
    PRIV_AUTH_READY=1
    log_ok "Sudo password securely stored in ${backend} keyring (application=${KEYRING_APP}, username=${usr})."
    log_ok "You can now run ./optimize-standby.sh without 'sudo'!"
}

run_clear_keyring() {
    log_section "Remove Saved Credentials from System Keyring"
    local usr backend
    usr="$(get_target_user)"
    backend="$(detect_keyring_backend)"

    case "${backend}" in
        libsecret)
            secret-tool clear application "${KEYRING_APP}" username "${usr}" 2>/dev/null || true
            ;;
        kwallet)
            log_info "Please remove folder '${KEYRING_APP}' in KWalletManager if present."
            ;;
    esac
    sudo -k 2>/dev/null || true
    PRIV_AUTH_READY=0
    log_ok "Cleared saved sudo credentials from keyring for user '${usr}'."
}

ensure_priv_auth() {
    if [[ "${DRY_RUN}" == "1" || "${EUID}" -eq 0 || "${PRIV_AUTH_READY}" == "1" ]]; then
        return 0
    fi

    local usr
    usr="$(get_target_user)"
    export SUDO_KEYRING_USER="${usr}"
    export SUDO_ASKPASS="${SCRIPT_DIR}/lib/askpass-keyring.sh"

    # 1. Check if sudo timestamp is already cached
    if sudo -n true 2>/dev/null; then
        PRIV_AUTH_READY=1
        return 0
    fi

    # 2. Try authenticating silently via system keyring (SUDO_ASKPASS)
    if keyring_has_secret; then
        if sudo -A -v 2>/dev/null; then
            log_ok "Authenticated automatically via system keyring ($(detect_keyring_backend))."
            PRIV_AUTH_READY=1
            return 0
        else
            log_warn "Stored password in system keyring failed sudo verification."
        fi
    fi

    # 3. Interactive fallback: offer to save in keyring once
    if [[ -t 0 ]]; then
        local backend
        backend="$(detect_keyring_backend)"
        if [[ "${backend}" != "none" ]]; then
            log_info "Privileged action required, and no valid password is saved in the ${backend} keyring yet."
            local reply
            read -r -p "Save sudo password in your desktop keyring so you don't need sudo next time? [Y/n]: " reply
            if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
                run_setup_keyring
                return 0
            fi
        fi
        log_info "Requesting one-time sudo authentication..."
        sudo -v
        PRIV_AUTH_READY=1
        return 0
    fi

    log_err "Root privileges required and no secret found in keyring. Run './optimize-standby.sh --setup-keyring' first."
    return 1
}
