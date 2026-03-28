#!/usr/bin/env bash
# vm-setup.sh — KrylixOS build environment setup
# Target: Fedora 43 Workstation
#
# SMART: detects what's already installed and skips it.
# Safe to re-run at any time.
#
# Usage (as regular user, NOT root):
#   cd /home/aman/KrylixOS
#   bash vm-setup.sh

##############################################################################
# 0. Resolve repo root — works even with no git commits yet
##############################################################################

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${REPO_ROOT}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   KrylixOS VM Setup — Fedora 43 Workstation         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Repo:    ${REPO_ROOT}"
echo "  User:    $(whoami)  (EUID=${EUID})"
echo "  CPUs:    $(nproc)   RAM: $(free -h | awk '/^Mem:/{print $2}')"
echo "  Disk:    $(df -BG "${HOME}" | awk 'NR==2{print $4}') free in ${HOME}"
echo ""

if [[ "${EUID}" -eq 0 && -z "${SUDO_USER:-}" ]]; then
    echo "⚠  You are running as root (not via sudo)."
    echo "   Recommended: exit root shell, run as 'aman', use sudo only when prompted."
    echo "   Continuing anyway — rpmbuild will use /root/rpmbuild."
    echo ""
fi

# Determine the actual user home for rpmbuild
if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
else
    REAL_HOME="${HOME}"
fi
RPMBUILD_DIR="${REAL_HOME}/rpmbuild"

##############################################################################
# Helper: check if a package is installed
##############################################################################

pkg_installed() { rpm -q "$1" &>/dev/null; }

##############################################################################
# Step 1 — Install only the missing packages
##############################################################################

echo "━━━ Step 1/6: Package check ━━━"

MISSING_PKGS=()

# Groups already installed per DNF history — just verify key ones
VERIFY=(gcc make openssl rpm-build rpmsign pesign sbsigntools checkpolicy
        policycoreutils selinux-policy-devel falco lorax pykickstart
        cryptsetup openscap)

ALL_PRESENT=true
for pkg in "${VERIFY[@]}"; do
    if ! pkg_installed "${pkg}"; then
        echo "  ✗ Missing verified package: ${pkg}"
        ALL_PRESENT=false
    fi
done
${ALL_PRESENT} && echo "  ✓ Core packages all present"

# Packages that were NOT in the DNF history — install these
NEED_INSTALL=(
    clevis-luks clevis-dracut clevis-pin-tpm2
    tpm2-abrmd jose luksmeta
    dracut dracut-config-rescue
    gnupg2
    dnf5 dnf5-plugins
)

TO_INSTALL=()
for pkg in "${NEED_INSTALL[@]}"; do
    if ! pkg_installed "${pkg}"; then
        TO_INSTALL+=("${pkg}")
    fi
done

if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
    echo "  Installing missing packages: ${TO_INSTALL[*]}"
    sudo dnf install -y "${TO_INSTALL[@]}"
    echo "  ✓ Missing packages installed"
else
    echo "  ✓ All required packages already present"
fi

##############################################################################
# Step 2 — rpmbuild tree
##############################################################################

echo ""
echo "━━━ Step 2/6: rpmbuild tree ━━━"
rpmdev-setuptree 2>/dev/null || mkdir -p "${RPMBUILD_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
echo "  ✓ ${RPMBUILD_DIR}/ ready"

##############################################################################
# Step 3 — MOK keypair (skip if already exists)
##############################################################################

echo ""
echo "━━━ Step 3/6: MOK keypair ━━━"

MOK_DIR="/etc/pki/krylix"
sudo mkdir -p "${MOK_DIR}"

if [[ -f "${MOK_DIR}/KrylixOS-dev.key" && -f "${MOK_DIR}/KrylixOS-ca.cer" ]]; then
    echo "  ✓ Already exists at ${MOK_DIR}/"
    openssl x509 -in "${MOK_DIR}/KrylixOS-ca.cer" -noout \
        -subject -enddate 2>/dev/null | sed 's/^/    /'
else
    echo "  Generating RSA-4096 dev MOK keypair..."
    sudo openssl req -newkey rsa:4096 -nodes \
        -keyout "${MOK_DIR}/KrylixOS-dev.key" \
        -new -x509 -sha256 -days 365 \
        -subj "/CN=KrylixOS Dev MOK Key (VM - NOT FOR PRODUCTION)/" \
        -out "${MOK_DIR}/KrylixOS-ca.cer"
    sudo chmod 640 "${MOK_DIR}/KrylixOS-dev.key"
    sudo chmod 644 "${MOK_DIR}/KrylixOS-ca.cer"
    sudo chown root:"$(whoami)" "${MOK_DIR}/KrylixOS-dev.key"
    echo "  ✓ Generated"
fi

##############################################################################
# Step 4 — GPG key (skip if already exists)
##############################################################################

echo ""
echo "━━━ Step 4/6: GPG signing key ━━━"

GPG_COUNT=$(gpg --list-keys 'KrylixOS Dev' 2>/dev/null | grep -c 'KrylixOS Dev' || echo "0")

if [[ "${GPG_COUNT}" -gt 0 ]]; then
    echo "  ✓ KrylixOS Dev key already exists"
else
    echo "  Generating RSA-4096 GPG key..."
    gpg --batch --gen-key << 'GPGEOF'
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: KrylixOS Dev
Name-Email: dev-build@krylix.local
Expire-Date: 1y
%no-passphrase
%commit
GPGEOF
    echo "  ✓ Generated"
fi

# Get the key ID (needed for rpmmacros and .env.dev)
GPG_KEY_ID=$(gpg --list-keys --with-colons 'KrylixOS Dev' 2>/dev/null | \
    grep '^pub' | head -1 | cut -d: -f5 || echo "")

if [[ -n "${GPG_KEY_ID}" ]]; then
    echo "  Key ID: ${GPG_KEY_ID}"
    mkdir -p "${REPO_ROOT}/repo"
    gpg --armor --export "${GPG_KEY_ID}" > "${REPO_ROOT}/repo/RPM-GPG-KEY-KrylixOS-dev"
    echo "  ✓ Public key → repo/RPM-GPG-KEY-KrylixOS-dev"
else
    echo "  ✗ Could not read GPG key ID — check: gpg --list-keys 'KrylixOS Dev'"
fi

##############################################################################
# Step 5 — ~/.rpmmacros (always rewrite to ensure correct key ID)
##############################################################################

echo ""
echo "━━━ Step 5/6: ~/.rpmmacros ━━━"

cat > "${REAL_HOME}/.rpmmacros" << EOF
%_topdir        ${RPMBUILD_DIR}
%_gpg_name      ${GPG_KEY_ID:-KrylixOS Dev}
%_signature     gpg
%_gpg_path      ~/.gnupg
EOF
echo "  ✓ Written to ${REAL_HOME}/.rpmmacros"
echo "    _topdir  = ${RPMBUILD_DIR}"
echo "    _gpg_name = ${GPG_KEY_ID:-KrylixOS Dev}"

##############################################################################
# Step 6 — .env.dev (always rewrite to ensure correct REPO_ROOT)
##############################################################################

echo ""
echo "━━━ Step 6/6: .env.dev ━━━"

cat > "${REPO_ROOT}/.env.dev" << ENVEOF
# KrylixOS VM build environment — Fedora 43 Workstation
# Source at the start of every session:  source .env.dev

export REPO_ROOT="${REPO_ROOT}"
export RPMBUILD_DIR="${RPMBUILD_DIR}"
export GPG_KEY_ID="${GPG_KEY_ID:-KrylixOS Dev}"
export MOK_PRIVATE_KEY_PEM=\$(sudo cat /etc/pki/krylix/KrylixOS-dev.key 2>/dev/null || echo "")
export KRYLIX_BUILD_ENV="vm"
export SOURCE_DATE_EPOCH=\$(git -C "${REPO_ROOT}" log -1 --format=%ct 2>/dev/null || date +%s)
ENVEOF

echo "  ✓ Written to ${REPO_ROOT}/.env.dev"
echo "    REPO_ROOT     = ${REPO_ROOT}"
echo "    RPMBUILD_DIR  = ${RPMBUILD_DIR}"
echo "    GPG_KEY_ID    = ${GPG_KEY_ID:-not set}"

# Make all scripts executable
find "${REPO_ROOT}/scripts" "${REPO_ROOT}/profiles" "${REPO_ROOT}/kernel" \
    -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
chmod +x "${REPO_ROOT}/verify-build.sh" "${REPO_ROOT}/vm-setup.sh" 2>/dev/null || true

##############################################################################
# Done
##############################################################################

KERN_MIN=$(( 140 / $(nproc) ))

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✅ Setup complete!                                 ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  %s CPUs · kernel ~%s min · total ~%s min              ║\n"     "$(nproc)" "${KERN_MIN}" "$(( KERN_MIN + 20 ))"
echo "║                                                      ║"
echo "║  Run these commands now:                             ║"
echo "║                                                      ║"
printf "║    source .env.dev                                   ║\n"
printf "║    bash scripts/01-build-selinux-policy.sh  # ~2min  ║\n"
printf "║    bash scripts/02-build-rpms.sh            # ~3min  ║\n"
printf "║    bash scripts/03-build-kernel.sh          # ~%smin ║\n" "${KERN_MIN}"
printf "║    bash scripts/04-build-iso.sh             # ~15min ║\n"
echo "║                                                      ║"
echo "║  Or all at once:                                     ║"
echo "║    bash scripts/build-all.sh                        ║"
echo "║                                                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
