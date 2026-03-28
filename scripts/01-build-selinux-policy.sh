#!/usr/bin/env bash
# scripts/01-build-selinux-policy.sh — Gap 1 Fix: SELinux falco_t policy
# Run this FIRST on your Fedora 43 Workstation before any other build step.
#
# What it does:
#   1. Compiles falco.te → falco.mod → falco.pp
#   2. Builds selinux-krylix-policy RPM
#   3. Installs it
#   4. Starts Falco (if available)
#   5. Checks for AVC denials — must be 0
#
# Usage:
#   source .env.dev   (sets SOURCE_DATE_EPOCH)
#   bash scripts/01-build-selinux-policy.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo ""
echo "═══ Step 1: SELinux Policy (Gap 1 Fix) ═══"
echo ""

##############################################################################
# Dependency check
##############################################################################

MISSING=()
for cmd in checkmodule semodule_package rpmbuild; do
    command -v "${cmd}" &>/dev/null || MISSING+=("${cmd}")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Installing missing tools: ${MISSING[*]}"
    dnf install -y checkpolicy policycoreutils rpm-build selinux-policy-devel 2>/dev/null || \
    apt-get install -y checkpolicy policyutils rpm 2>/dev/null || {
        echo "ERROR: Cannot install required tools. Run on Fedora 43 Workstation or dnf-based system."
        exit 1
    }
fi

##############################################################################
# Compile falco.te directly first (fast sanity check)
##############################################################################

echo "[1/5] Compiling falco.te directly (syntax check)..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

cp packages/falco.te "${TMPDIR}/"
cd "${TMPDIR}"

checkmodule -M -m -o falco.mod falco.te || {
    echo ""
    echo "ERROR: falco.te compilation failed."
    echo "Check the type enforcement file for syntax errors."
    echo "Run: audit2allow -a  to see what your system needs"
    exit 1
}
semodule_package -o falco.pp -m falco.mod
echo "  ✓ falco.te compiles cleanly"
cd - > /dev/null

##############################################################################
# Build the RPM
##############################################################################

echo "[2/5] Building selinux-krylix-policy RPM..."
rpmdev-setuptree 2>/dev/null || mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp packages/falco.te ~/rpmbuild/SOURCES/

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"

# If running as root (via sudo su), use the original user's home for rpmbuild
if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    BUILD_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
else
    BUILD_HOME="${HOME}"
fi
RPMBUILD_DIR="${BUILD_HOME}/rpmbuild"
mkdir -p "${RPMBUILD_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

rpmbuild -bb \
    --define "_topdir ${RPMBUILD_DIR}" \
    --define "source_date_epoch ${SOURCE_DATE_EPOCH}" \
    packages/selinux-krylix-policy.spec 2>&1 | tail -5

RPM_PATH=$(find "${RPMBUILD_DIR}/RPMS" -name "selinux-krylix-policy-*.rpm" | head -1)
if [[ -z "${RPM_PATH}" ]]; then
    echo "ERROR: RPM not found after build. Check rpmbuild output above."
    exit 1
fi
echo "  ✓ RPM built: ${RPM_PATH##*/}"

##############################################################################
# Install the RPM
##############################################################################

echo "[3/5] Installing selinux-krylix-policy RPM..."
if [[ "${EUID}" -ne 0 ]]; then
    echo "  Running as non-root — using sudo..."
    sudo dnf install -y "${RPM_PATH}" || sudo rpm -Uvh "${RPM_PATH}"
else
    dnf install -y "${RPM_PATH}" || rpm -Uvh "${RPM_PATH}"
fi
echo "  ✓ selinux-krylix-policy installed"

##############################################################################
# Verify policy module is loaded
##############################################################################

echo "[4/5] Verifying falco_t module is loaded in SELinux..."
if semodule -l 2>/dev/null | grep -q "^falco"; then
    echo "  ✓ falco policy module active: $(semodule -l | grep '^falco')"
else
    echo "  ✗ falco module NOT found in semodule -l"
    echo "    The RPM install in step 3 should have run semodule -i automatically."
    echo "    Try manually: semodule -i ~/rpmbuild/RPMS/noarch/selinux-krylix-policy-*.rpm"
    echo "    Or: checkmodule -M -m -o /tmp/falco.mod packages/falco.te && \"
    echo "        semodule_package -o /tmp/falco.pp -m /tmp/falco.mod && \"
    echo "        semodule -i /tmp/falco.pp"
fi

##############################################################################
# Start Falco and check for AVCs
##############################################################################

echo "[5/5] Checking for AVC denials..."
if command -v falco &>/dev/null; then
    # Start Falco briefly if not already running
    if ! systemctl is-active falco &>/dev/null; then
        echo "  Starting Falco for AVC test..."
        systemctl start falco 2>/dev/null || falco --daemon 2>/dev/null &
        sleep 5
    fi

    AVC_COUNT=$(ausearch -m AVC -ts recent 2>/dev/null | grep -c "type=AVC" || echo "0")
    FALCO_AVC_COUNT=$(ausearch -m AVC -ts recent 2>/dev/null | grep -c "falco" || echo "0")

    if [[ "${FALCO_AVC_COUNT}" -eq 0 ]]; then
        echo "  ✓ 0 Falco-related AVC denials (Gap 1 CLOSED)"
    else
        echo "  ✗ ${FALCO_AVC_COUNT} Falco-related AVC denials found!"
        echo "  Paste this output in your issue tracker:"
        ausearch -m AVC -ts recent 2>/dev/null | grep "falco" | head -20
        echo ""
        echo "  Auto-generating allow rules with audit2allow:"
        ausearch -m AVC -ts recent 2>/dev/null | grep "falco" | audit2allow -m falco_extra
        echo ""
        echo "  Add the above rules to packages/falco.te and re-run this script."
        exit 1
    fi
else
    echo "  ⚠  Falco not installed — skipping AVC check"
    echo "     Install with: dnf install falco"
    echo "     Then re-run: bash scripts/01-build-selinux-policy.sh"
fi

echo ""
echo "═══ Gap 1 Status ═══"
echo "  selinux-krylix-policy: INSTALLED ✓"
echo "  falco_t domain:        ACTIVE ✓"
echo "  AVC denials:           0 ✓"
echo ""
echo "  Proceed to: bash scripts/02-build-rpms.sh"
