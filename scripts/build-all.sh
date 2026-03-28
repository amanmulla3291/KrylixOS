#!/usr/bin/env bash
# scripts/build-all.sh — Run the complete KrylixOS build chain
#
# Usage (from repo root on Fedora 43 Workstation):
#   source .env.dev
#   bash scripts/build-all.sh
#
# To skip steps you've already done:
#   SKIP_SELINUX=1 bash scripts/build-all.sh
#   SKIP_KERNEL=1  bash scripts/build-all.sh
#   SKIP_ISO=1     bash scripts/build-all.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SKIP_SELINUX="${SKIP_SELINUX:-0}"
SKIP_RPMS="${SKIP_RPMS:-0}"
SKIP_KERNEL="${SKIP_KERNEL:-0}"
SKIP_ISO="${SKIP_ISO:-0}"

# Handle no git commits (git log returns error if no commits yet)
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}"

# Warn if running as root without SUDO_USER (can cause rpmbuild path issues)
if [[ "${EUID}" -eq 0 && -z "${SUDO_USER:-}" ]]; then
    echo "⚠  Running as root (not via sudo). rpmbuild will use /root/rpmbuild."
    echo "   Recommended: run as your regular user with sudo for dnf steps only."
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   KrylixOS Full Build                               ║"
echo "║   $(date -u '+%Y-%m-%d %H:%M UTC')                        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

START_TOTAL=$(date +%s)

if [[ "${SKIP_SELINUX}" != "1" ]]; then
    echo "━━━ 01/04 SELinux Policy (Gap 1 fix) ━━━"
    bash scripts/01-build-selinux-policy.sh
fi

if [[ "${SKIP_RPMS}" != "1" ]]; then
    echo "━━━ 02/04 RPM Packages ━━━"
    bash scripts/02-build-rpms.sh
fi

if [[ "${SKIP_KERNEL}" != "1" ]]; then
    echo "━━━ 03/04 Kernel ━━━"
    bash scripts/03-build-kernel.sh
fi

if [[ "${SKIP_ISO}" != "1" ]]; then
    echo "━━━ 04/04 ISO ━━━"
    bash scripts/04-build-iso.sh
fi

END_TOTAL=$(date +%s)
ELAPSED=$(( (END_TOTAL - START_TOTAL) / 60 ))

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✅ KrylixOS build complete (${ELAPSED} min)               ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║   Next: bash verify-build.sh --profile=vm --verbose ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
