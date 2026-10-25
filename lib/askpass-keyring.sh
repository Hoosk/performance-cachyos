#!/usr/bin/env bash
# SUDO_ASKPASS helper that retrieves the user's sudo password from the desktop keyring
# Supports libsecret (secret-tool / GNOME Keyring / KeePassXC) and KDE KWallet.

set -euo pipefail

TARGET_USER="${SUDO_KEYRING_USER:-${USER:-$(id -un)}}"
KEYRING_APP="standby-optimizer"

if command -v secret-tool >/dev/null 2>&1; then
    if secret-tool lookup application "${KEYRING_APP}" username "${TARGET_USER}" 2>/dev/null; then
        exit 0
    fi
fi

if command -v kwallet-query >/dev/null 2>&1; then
    if kwallet-query kdewallet -f "${KEYRING_APP}" -r "${TARGET_USER}" 2>/dev/null; then
        exit 0
    fi
fi

exit 1
