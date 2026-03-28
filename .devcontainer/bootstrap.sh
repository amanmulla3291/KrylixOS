#!/usr/bin/env bash
# bootstrap.sh — Run this if setup.sh didn't fire automatically
#
# Paste this single command in your Codespace terminal:
#   bash .devcontainer/bootstrap.sh
#
# What it does:
#   1. Installs ncurses-term (fixes "clear: command not found")
#   2. Runs the full setup.sh
#   3. Writes .env.dev in the current directory
#   4. Prints what to do next

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${REPO_ROOT}"

echo ""
echo "KrylixOS bootstrap — fixing environment..."
echo "Repo root: ${REPO_ROOT}"
echo ""

# Fix 'clear: command not found' immediately
dnf install -y --quiet ncurses ncurses-term 2>/dev/null || true
hash -r   # refresh PATH cache so clear works in this shell

# Run the full setup if not already done
if [[ ! -f /etc/pki/krylix/KrylixOS-dev.key ]]; then
    echo "Running full setup (first time — takes ~5 min)..."
    bash .devcontainer/setup.sh
else
    echo "Full setup already done — skipping to .env.dev write."
fi

# Write .env.dev relative to repo root (idempotent)
cat > "${REPO_ROOT}/.env.dev" << 'ENVEOF'
# KrylixOS Codespace .env
# Run: source .env.dev
export MOK_PRIVATE_KEY_PEM=$(cat /etc/pki/krylix/KrylixOS-dev.key 2>/dev/null || echo "")
export KRYLIX_BUILD_ENV="codespace"
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || date +%s)
ENVEOF

echo ""
echo "✅ Bootstrap complete. Now run:"
echo ""
echo "   source .env.dev"
echo "   bash scripts/01-build-selinux-policy.sh"
echo ""
