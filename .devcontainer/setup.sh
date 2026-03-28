#!/usr/bin/env bash
# .devcontainer/setup.sh — KrylixOS Codespace build environment setup
# Runs once after container creation (postCreateCommand)
# Installs all tools needed to: compile kernel, build RPMs, build ISO, sign everything

set -euo pipefail

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   KrylixOS Codespace Environment Setup              ║"
echo "║   Fedora 41 — Kernel → RPM → ISO build chain        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

##############################################################################
# 1. System update
##############################################################################

echo "[setup] Updating base system..."
dnf update -y --quiet

##############################################################################
# 2. Core build tools
##############################################################################

echo "[setup] Installing build dependencies..."
dnf install -y --quiet \
    @development-tools \
    gcc gcc-c++ make automake autoconf libtool \
    flex bison \
    bc perl \
    openssl openssl-devel \
    elfutils elfutils-libelf elfutils-libelf-devel elfutils-devel \
    libelf-devel \
    python3 python3-devel python3-pip \
    dwarves pahole \
    xz xz-devel \
    zlib-devel \
    ncurses-devel \
    curl wget \
    jq \
    git

##############################################################################
# 3. RPM build and signing tools
##############################################################################

echo "[setup] Installing RPM build tools..."
dnf install -y --quiet \
    rpm-build \
    rpm-devel \
    rpmsign \
    rpmdevtools \
    createrepo_c \
    mock \
    koji-utils 2>/dev/null || true

##############################################################################
# 4. Secure Boot / MOK signing tools
##############################################################################

echo "[setup] Installing Secure Boot tools..."
dnf install -y --quiet \
    pesign \
    sbsigntools \
    efitools \
    shim-unsigned 2>/dev/null || true

##############################################################################
# 5. SELinux policy build tools (Gap 1 fix dependencies)
##############################################################################

echo "[setup] Installing SELinux policy tools..."
dnf install -y --quiet \
    selinux-policy \
    selinux-policy-devel \
    selinux-policy-targeted \
    checkpolicy \
    policycoreutils \
    policycoreutils-python-utils \
    libselinux-utils \
    setools-console \
    audit \
    ausearch \
    setroubleshoot-server 2>/dev/null || true

##############################################################################
# 6. ISO build tools
##############################################################################

echo "[setup] Installing ISO build tools..."
dnf install -y --quiet \
    lorax \
    anaconda-core \
    pykickstart \
    genisoimage \
    isomd5sum 2>/dev/null || true

# mkksiso ships inside lorax-tools or as standalone
dnf install -y --quiet lorax-lmc-novirt 2>/dev/null || true

##############################################################################
# 7. Security / IDS tools (for verify-build.sh testing)
##############################################################################

echo "[setup] Installing security tools..."
dnf install -y --quiet \
    falco 2>/dev/null || {
    # Falco not in default Fedora — add repo
    echo "[setup] Adding Falco RPM repo..."
    rpm --import https://falco.org/repo/falcosecurity-packages.asc 2>/dev/null || true
    curl -fsSL -o /etc/yum.repos.d/falcosecurity.repo \
        https://falco.org/repo/falcosecurity-rpm.repo 2>/dev/null || true
    dnf install -y --quiet falco 2>/dev/null || \
        echo "[setup] WARNING: Falco install failed — install manually for AVC testing"
}

dnf install -y --quiet \
    openscap \
    openscap-scanner \
    scap-security-guide 2>/dev/null || true

##############################################################################
# 8. TPM2 / Clevis / LUKS tools (for profile scripts)
##############################################################################

echo "[setup] Installing LUKS2/TPM2/Clevis tools..."
dnf install -y --quiet \
    cryptsetup \
    lvm2 \
    clevis \
    clevis-luks \
    clevis-dracut \
    clevis-pin-tpm2 \
    tpm2-tools \
    tpm2-abrmd \
    jose \
    luksmeta \
    dracut \
    dracut-config-rescue 2>/dev/null || true

##############################################################################
# 9. dnf5 (pinned >= 5.2)
##############################################################################

echo "[setup] Installing dnf5..."
dnf install -y --quiet \
    dnf5 \
    dnf5-plugins 2>/dev/null || true

##############################################################################
# 10. GPG for repo signing
##############################################################################

echo "[setup] Installing GPG tools..."
dnf install -y --quiet gnupg2

##############################################################################
# 11. Shell tooling for CI scripts
##############################################################################

echo "[setup] Installing shell tools..."
dnf install -y --quiet \
    bash \
    shellcheck \
    shfmt 2>/dev/null || true

##############################################################################
# 12. Set up RPM build tree
##############################################################################

echo "[setup] Setting up rpmbuild directory tree..."
rpmdev-setuptree 2>/dev/null || mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

##############################################################################
# 13. Generate dev MOK keypair (for local signing — NOT for production)
#     Production uses GitHub Secrets (MOK_PRIVATE_KEY_PEM + MOK_CERT_PEM)
##############################################################################

MOK_DIR="/etc/pki/krylix"
mkdir -p "${MOK_DIR}"

if [[ ! -f "${MOK_DIR}/KrylixOS-dev.key" ]]; then
    echo "[setup] Generating development MOK keypair (Codespace only)..."
    openssl req -newkey rsa:4096 \
        -nodes \
        -keyout "${MOK_DIR}/KrylixOS-dev.key" \
        -new \
        -x509 \
        -sha256 \
        -days 365 \
        -subj "/CN=KrylixOS Dev MOK Key (Codespace - NOT FOR PRODUCTION)/" \
        -out "${MOK_DIR}/KrylixOS-ca.cer"
    chmod 600 "${MOK_DIR}/KrylixOS-dev.key"
    chmod 644 "${MOK_DIR}/KrylixOS-ca.cer"
    echo "[setup] Dev MOK keypair generated:"
    echo "  Key:  ${MOK_DIR}/KrylixOS-dev.key"
    echo "  Cert: ${MOK_DIR}/KrylixOS-ca.cer"
    echo "  NOTE: For production CI, set MOK_PRIVATE_KEY_PEM + MOK_CERT_PEM as GitHub Secrets"
else
    echo "[setup] Dev MOK keypair already exists — skipping generation"
fi

##############################################################################
# 14. Generate dev GPG key for RPM signing (Codespace only)
##############################################################################

GPG_KEY_EXISTS=$(gpg --list-keys 'KrylixOS Dev' 2>/dev/null | grep -c 'KrylixOS Dev' || echo "0")
if [[ "${GPG_KEY_EXISTS}" -eq 0 ]]; then
    echo "[setup] Generating development GPG key for RPM signing..."
    gpg --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: KrylixOS Dev
Name-Email: dev-build@krylix.local
Expire-Date: 1y
%no-passphrase
%commit
EOF
    echo "[setup] Dev GPG key generated."
    echo "  NOTE: Export public key with: gpg --armor --export 'KrylixOS Dev' > RPM-GPG-KEY-KrylixOS-dev"
else
    echo "[setup] Dev GPG key already exists — skipping"
fi

# Export public key to repo dir for local dnf testing
mkdir -p /workspaces/KrylixOS/repo 2>/dev/null || true
gpg --armor --export 'KrylixOS Dev' > \
    /workspaces/KrylixOS/repo/RPM-GPG-KEY-KrylixOS-dev 2>/dev/null || true

##############################################################################
# 15. Set up ~/.rpmmacros for signing
##############################################################################

GPG_KEY_ID=$(gpg --list-keys --with-colons 'KrylixOS Dev' 2>/dev/null | \
    grep '^pub' | head -1 | cut -d: -f5 || echo "")

if [[ -n "${GPG_KEY_ID}" ]]; then
    cat > ~/.rpmmacros << EOF
%_topdir        %(echo \$HOME)/rpmbuild
%_gpg_name      ${GPG_KEY_ID}
%_gpg_path      ~/.gnupg
%__gpg_sign_cmd %{__gpg} \\
    gpg --batch --no-verbose --no-armor \\
    --passphrase-fd 3 --no-secmem-warning \\
    -u "%{_gpg_name}" -sbo %{__signature_filename} \\
    --digest-algo sha256 %{__plaintext_filename}
EOF
    echo "[setup] ~/.rpmmacros configured for GPG signing with key ${GPG_KEY_ID}"
fi

##############################################################################
# 16. Export DEV MOK key as env var (for build-kernel.sh in Codespace)
##############################################################################

MOK_KEY_EXPORT_SCRIPT="/etc/profile.d/krylix-dev.sh"
cat > "${MOK_KEY_EXPORT_SCRIPT}" << 'ENVSCRIPT'
# KrylixOS Codespace development environment
# Dev MOK key available for local kernel signing
export MOK_PRIVATE_KEY_PEM=$(cat /etc/pki/krylix/KrylixOS-dev.key 2>/dev/null || echo "")
export KRYLIX_BUILD_ENV="codespace"
export SOURCE_DATE_EPOCH=$(git -C "${CODESPACE_VSCODE_FOLDER:-/workspaces/KrylixOS}" log -1 --format=%ct 2>/dev/null || date +%s)
ENVSCRIPT
chmod 644 "${MOK_KEY_EXPORT_SCRIPT}"

# Write .env.dev relative to the repo root — works regardless of /workspaces path
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || echo "/workspaces/KrylixOS")"
cat > "${REPO_ROOT}/.env.dev" << 'DEVENV'
# KrylixOS Codespace .env — source this in your terminal: source .env.dev
export MOK_PRIVATE_KEY_PEM=$(cat /etc/pki/krylix/KrylixOS-dev.key 2>/dev/null || echo "")
export KRYLIX_BUILD_ENV="codespace"
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || date +%s)
export PATH="${PATH}:/usr/bin"
DEVENV

##############################################################################
# Done
##############################################################################

CORES=$(nproc)
KERN_MIN=$(( 140 / CORES ))   # rough: ~140 CPU-minutes for 6.12.y

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✅ KrylixOS Codespace environment ready!          ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                      ║"
printf "║  Machine: %s cores  (kernel compile ~%s min)\n" "${CORES}" "${KERN_MIN}"
echo "║                                                      ║"
echo "║  Quick start:                                        ║"
echo "║    source .env.dev                                   ║"
echo "║    bash scripts/build-all.sh                        ║"
echo "║                                                      ║"
echo "║  Step by step:                                       ║"
echo "║    bash scripts/01-build-selinux-policy.sh  # Gap 1 ║"
echo "║    bash scripts/02-build-rpms.sh                    ║"
echo "║    bash scripts/03-build-kernel.sh   # ~${KERN_MIN} min    ║"
echo "║    bash scripts/04-build-iso.sh                     ║"
echo "║                                                      ║"
echo "║  Verify:                                             ║"
echo "║    bash verify-build.sh --profile=vm --verbose      ║"
echo "║                                                      ║"
echo "║  ⚠  Dev keys are for Codespace ONLY                 ║"
echo "║     See SECRETS-SETUP.md before pushing to main     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
