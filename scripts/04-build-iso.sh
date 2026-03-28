#!/usr/bin/env bash
# scripts/04-build-iso.sh — Build KrylixOS bootable ISO
# Requires: steps 01-03 completed (RPMs + kernel built)
#
# Usage:
#   source .env.dev
#   bash scripts/04-build-iso.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo ""
echo "═══ Step 4: Build ISO ═══"
echo ""

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}"
BUILD_DATE=$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y%m%d' 2>/dev/null || date -u '+%Y%m%d')
ISO_NAME="KrylixOS-1.2-x86_64-${BUILD_DATE}.iso"
OUTPUT_DIR="/tmp/krylix-iso-output"

mkdir -p "${OUTPUT_DIR}"

##############################################################################
# Collect RPMs
##############################################################################

RPM_REPO="/tmp/krylix-local-repo"
mkdir -p "${RPM_REPO}"

echo "[iso] Collecting RPMs..."
find ~/rpmbuild/RPMS -name "*.rpm" -exec cp {} "${RPM_REPO}/" \;

RPM_COUNT=$(find "${RPM_REPO}" -name "*.rpm" | wc -l)
echo "[iso]   ${RPM_COUNT} RPMs collected"

if [[ "${RPM_COUNT}" -eq 0 ]]; then
    echo "[iso] ERROR: No RPMs found. Run steps 01-03 first."
    exit 1
fi

# Create local repo metadata
createrepo_c "${RPM_REPO}/"

##############################################################################
# Validate Kickstart
##############################################################################

echo "[iso] Validating Kickstart..."
if command -v ksvalidator &>/dev/null; then
    ksvalidator iso/ks.cfg && echo "[iso]   ✓ Kickstart valid" || {
        echo "[iso]   ✗ Kickstart invalid — check iso/ks.cfg"
        exit 1
    }
else
    echo "[iso]   ⚠  ksvalidator not found — skipping (install pykickstart)"
fi

##############################################################################
# Build with lorax
##############################################################################

if ! command -v lorax &>/dev/null; then
    echo "[iso] ERROR: lorax not installed."
    echo "     Run: dnf install lorax lorax-lmc-novirt"
    exit 1
fi

echo "[iso] Running lorax (this takes ~10-15 min)..."
export SOURCE_DATE_EPOCH

lorax \
    --product "KrylixOS Linux" \
    --version "1.2" \
    --release "${BUILD_DATE}" \
    --source "https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/" \
    --source "file://${RPM_REPO}/" \
    --logfile "${OUTPUT_DIR}/lorax.log" \
    --rootfs-size 4 \
    "${OUTPUT_DIR}/lorax/" 2>&1 | tee "${OUTPUT_DIR}/lorax.log" | \
    grep -E "(INFO|WARNING|ERROR|Wrote)" | tail -20 || {
    echo "[iso] lorax failed — check ${OUTPUT_DIR}/lorax.log"
    exit 1
}

##############################################################################
# Inject Kickstart
##############################################################################

BOOT_ISO="${OUTPUT_DIR}/lorax/images/boot.iso"
if [[ ! -f "${BOOT_ISO}" ]]; then
    echo "[iso] ERROR: boot.iso not found at ${BOOT_ISO}"
    exit 1
fi

FINAL_ISO="/tmp/${ISO_NAME}"

if command -v mkksiso &>/dev/null; then
    echo "[iso] Injecting Kickstart with mkksiso..."
    mkksiso --ks iso/ks.cfg "${BOOT_ISO}" "${FINAL_ISO}"
    echo "[iso]   ✓ Kickstart injected"
else
    echo "[iso]   ⚠  mkksiso not available — Kickstart not embedded"
    echo "       Install: dnf install lorax-lmc-novirt"
    cp "${BOOT_ISO}" "${FINAL_ISO}"
fi

##############################################################################
# Checksums + GPG signature
##############################################################################

echo "[iso] Generating SHA256 checksum..."
cd /tmp
sha256sum "${ISO_NAME}" > SHA256SUMS

GPG_KEY_ID=$(gpg --list-keys --with-colons 2>/dev/null | \
    grep '^pub' | head -1 | cut -d: -f5 || echo "")
if [[ -n "${GPG_KEY_ID}" ]]; then
    gpg --batch --yes \
        --default-key "${GPG_KEY_ID}" \
        --detach-sign --armor SHA256SUMS
    echo "[iso]   ✓ SHA256SUMS.asc signed"
fi

##############################################################################
# Summary
##############################################################################

ISO_SIZE=$(du -sh "${FINAL_ISO}" | cut -f1)
SHA256=$(sha256sum "${FINAL_ISO}" | cut -d' ' -f1)

echo ""
echo "═══ ISO Build Complete ═══"
echo "  File:   /tmp/${ISO_NAME}"
echo "  Size:   ${ISO_SIZE} (target < 550 MB)"
echo "  SHA256: ${SHA256}"
echo ""
echo "  Verify: bash verify-build.sh --profile=vm --verbose"
echo ""

# Size check
ISO_MB=$(du -sm "${FINAL_ISO}" | cut -f1)
if [[ "${ISO_MB}" -gt 550 ]]; then
    echo "  ⚠  ISO size ${ISO_MB} MB exceeds 550 MB target — review package list"
fi
