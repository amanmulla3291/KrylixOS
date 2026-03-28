#!/usr/bin/env bash
# scripts/02-build-rpms.sh — Build all KrylixOS RPM packages
# Run after 01-build-selinux-policy.sh
#
# Usage:
#   source .env.dev
#   bash scripts/02-build-rpms.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo ""
echo "═══ Step 2: Build RPM Packages ═══"
echo ""

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
# Respect RPMBUILD_DIR from .env.dev; fall back to SUDO_USER-aware detection
if [[ -z "${RPMBUILD_DIR:-}" ]]; then
    if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        RPMBUILD_DIR="$(getent passwd "${SUDO_USER}" | cut -d: -f6)/rpmbuild"
    else
        RPMBUILD_DIR="${HOME}/rpmbuild"
    fi
fi
mkdir -p "${RPMBUILD_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Copy sources
cp packages/falco.te "${RPMBUILD_DIR}/SOURCES/" 2>/dev/null || true

BUILD_SPECS=(
    packages/selinux-krylix-policy.spec
    packages/krylix-release.spec
    packages/falco-rules-krylix.spec
    packages/suricata-rules-krylix.spec
)

for spec in "${BUILD_SPECS[@]}"; do
    name=$(basename "${spec}" .spec)
    echo "[rpm] Building: ${name}..."
    rpmbuild -bb \
        --define "_topdir ${RPMBUILD_DIR}" \
        --define "source_date_epoch ${SOURCE_DATE_EPOCH}" \
        "${spec}" 2>&1 | grep -E "^(Wrote|error:|ERROR)" || true
done

##############################################################################
# Sign with dev GPG key (VM) or production key (CI)
##############################################################################

GPG_KEY_ID=$(gpg --list-keys --with-colons 2>/dev/null | \
    grep '^pub' | head -1 | cut -d: -f5 || echo "")

if [[ -n "${GPG_KEY_ID}" ]]; then
    echo "[rpm] Signing RPMs with key ${GPG_KEY_ID}..."
    find "${RPMBUILD_DIR}/RPMS" -name "*.rpm" | while read -r rpm; do
        rpmsign \
            --define "_gpg_name ${GPG_KEY_ID}" \
            --define "__gpg_check_password_cmd /bin/true" \
            --addsign "${rpm}" 2>/dev/null && \
            echo "  ✓ ${rpm##*/}" || \
            echo "  ⚠  Signing failed for ${rpm##*/} — continuing"
    done
else
    echo "  ⚠  No GPG key found — RPMs unsigned (run setup.sh first)"
fi

##############################################################################
# Summary
##############################################################################

echo ""
echo "Built RPMs:"
find "${RPMBUILD_DIR}/RPMS" -name "*.rpm" | while read -r rpm; do
    echo "  $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "${rpm}" 2>/dev/null)"
done

echo ""
echo "  Proceed to: bash scripts/03-build-kernel.sh"
echo "  (kernel compile ~70 min on 2-core VM — this is normal, be patient)"
