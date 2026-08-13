#!/bin/bash
# =============================================================================
# create_ansible_user.sh
# Creates the svc_ansible_local account for AAP initial access and break-glass.
#
# Usage: sudo ./create_ansible_user.sh
#
# This script is idempotent — safe to run multiple times.
# =============================================================================

set -euo pipefail

USERNAME="svc_ansible_local"
COMMENT="Ansible Service Account - Break Glass / Bootstrap"
SUDOERS_FILE="/etc/sudoers.d/${USERNAME}"

# --- Preflight ---------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

# --- User Creation -----------------------------------------------------------
if id "${USERNAME}" &>/dev/null; then
    echo "User ${USERNAME} already exists. Skipping creation."
else
    useradd \
        --comment "${COMMENT}" \
        --shell /bin/bash \
        --create-home \
        --system \
        "${USERNAME}"
    echo "Created user ${USERNAME}"
fi

# --- Set Password -------------------------------------------------------------
echo ""
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"

# --- Sudo Configuration ------------------------------------------------------
cat > "${SUDOERS_FILE}" <<EOF
# Managed manually - Ansible break-glass / bootstrap account
${USERNAME} ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 "${SUDOERS_FILE}"

if visudo -cf "${SUDOERS_FILE}" &>/dev/null; then
    echo "Sudo configured for ${USERNAME} — syntax validated"
else
    echo "ERROR: Sudoers syntax check failed" >&2
    rm -f "${SUDOERS_FILE}"
    exit 1
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Account: ${USERNAME}"
echo "  Purpose: AAP bootstrap access / break-glass"
echo "  Sudo:    NOPASSWD ALL"
echo "  Next:    Add system to AAP inventory with password credential"
echo "================================================================"
