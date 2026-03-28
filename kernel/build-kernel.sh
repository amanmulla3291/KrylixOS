#!/usr/bin/env bash
# build-kernel.sh — KrylixOS Linux Kernel Build Script
# Bootstrap host: Fedora 43 (host VM)
# Do NOT use Fedora 43/44 until released and stable
# Auto-tracks Linux 6.12.y LTS from kernel.org

set -euo pipefail
IFS=$'\n\t'

##############################################################################
# Configuration
##############################################################################

DIST_NAME="KrylixOS"
BUILD_USER="amanmulla3291"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/kernel-krylix.config"
RPMBUILD_DIR="${HOME}/rpmbuild"
MOK_CERT="/etc/pki/krylix/KrylixOS-ca.cer"
MOK_KEY_ENV="MOK_PRIVATE_KEY_PEM"     # injected by GitHub Actions OIDC → Vault
JOBS=$(nproc)

##############################################################################
# Reproducible builds — set SOURCE_DATE_EPOCH from git history
##############################################################################

if git -C "${SCRIPT_DIR}" rev-parse --git-dir &>/dev/null; then
    export SOURCE_DATE_EPOCH=$(git -C "${SCRIPT_DIR}" log -1 --format=%ct)
else
    export SOURCE_DATE_EPOCH=$(date -u +%s)
fi
echo "[kernel] SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"

##############################################################################
# Auto-detect latest Linux 6.12.y LTS kernel
##############################################################################

echo "[kernel] Fetching latest 6.12.y LTS version from kernel.org..."
KERNEL_VERSION=$(curl -fsSL https://www.kernel.org/releases.json | \
    jq -r '.releases[] |
        select(.moniker=="longterm") |
        select(.version | startswith("6.12")) |
        .version' | \
    head -1)

if [[ -z "${KERNEL_VERSION}" ]]; then
    echo "[kernel] ERROR: Could not detect 6.12.y LTS. Aborting." >&2
    exit 1
fi

echo "[kernel] Target kernel: ${KERNEL_VERSION}"
KERNEL_MAJOR=$(echo "${KERNEL_VERSION}" | cut -d. -f1)
KERNEL_MINOR=$(echo "${KERNEL_VERSION}" | cut -d. -f2)
TARBALL="linux-${KERNEL_VERSION}.tar.xz"
TARBALL_SIG="linux-${KERNEL_VERSION}.tar.sign"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${TARBALL}"
SIG_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${TARBALL_SIG}"

##############################################################################
# Dependency check
##############################################################################

DEPS=(gcc make flex bison openssl openssl-devel elfutils-libelf-devel \
      bc perl rpm-build pesign sbsigntools curl jq gpg)

echo "[kernel] Checking build dependencies..."
MISSING=()
for dep in "${DEPS[@]}"; do
    if ! rpm -q "${dep}" &>/dev/null && ! command -v "${dep}" &>/dev/null; then
        MISSING+=("${dep}")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "[kernel] Installing missing deps: ${MISSING[*]}"
    dnf install -y "${MISSING[@]}"
fi

##############################################################################
# Download and verify kernel tarball
##############################################################################

WORKDIR=$(mktemp -d /tmp/krylix-kernel-XXXXXX)
trap 'rm -rf "${WORKDIR}"' EXIT

cd "${WORKDIR}"
echo "[kernel] Downloading ${TARBALL}..."
curl -fsSL -o "${TARBALL}" "${KERNEL_URL}"
curl -fsSL -o "${TARBALL_SIG}" "${SIG_URL}"

# Verify GPG signature from kernel.org maintainers
gpg --locate-keys torvalds@kernel.org gregkh@kernel.org 2>/dev/null || true
xz -d "${TARBALL}"
gpg --verify "${TARBALL_SIG}" "linux-${KERNEL_VERSION}.tar" || {
    echo "[kernel] ERROR: GPG verification failed for kernel tarball!" >&2
    exit 1
}
tar xf "linux-${KERNEL_VERSION}.tar"
cd "linux-${KERNEL_VERSION}"

##############################################################################
# Apply hardened kernel config
##############################################################################

cp "${CONFIG_FILE}" .config
make olddefconfig
# Enforce critical security options — override any Kconfig defaults
scripts/config \
    --enable  CONFIG_SECURITY_SELINUX \
    --disable CONFIG_SECURITY_SELINUX_BOOTPARAM \
    --enable  CONFIG_LOCKDOWN_LSM \
    --enable  CONFIG_MODULE_SIG_FORCE \
    --enable  CONFIG_STACKPROTECTOR_STRONG \
    --enable  CONFIG_STRICT_KERNEL_RWX \
    --enable  CONFIG_HARDENED_USERCOPY \
    --enable  CONFIG_INIT_ON_ALLOC_DEFAULT_ON \
    --enable  CONFIG_INIT_ON_FREE_DEFAULT_ON \
    --enable  CONFIG_RANDOMIZE_BASE \
    --enable  CONFIG_BPF_SYSCALL \
    --enable  CONFIG_CGROUPS \
    --enable  CONFIG_CGROUP_BPF \
    --enable  CONFIG_NET_SCH_INGRESS \
    --enable  CONFIG_ENA_ETH \
    --enable  CONFIG_NVME_CORE \
    --enable  CONFIG_BLK_DEV_NVME \
    --disable CONFIG_BT \
    --disable CONFIG_SOUND \
    --disable CONFIG_SND \
    --disable CONFIG_USB_PRINTER \
    --disable CONFIG_HAMRADIO \
    --disable CONFIG_SCSI_TAPE \
    --disable CONFIG_STAGING

make olddefconfig

##############################################################################
# Compile
##############################################################################

# 2-core VM ~70 min | 4-core: ~35 min | 8-core: ~18 min | 16-core CI: ~10 min
echo "[kernel] Compiling kernel (${JOBS} jobs) — expected ~$(( 140 / JOBS )) min..."
echo "[kernel] TIP: ${JOBS}-core build is ~$(( 140 / JOBS )) min. Get coffee — this is normal ☕"
time make -j"${JOBS}" \
    KBUILD_BUILD_USER="${BUILD_USER}" \
    KBUILD_BUILD_HOST="${DIST_NAME}" \
    KBUILD_BUILD_TIMESTAMP="$(date -u -d @${SOURCE_DATE_EPOCH} '+%Y-%m-%d')" \
    bzImage modules

##############################################################################
# MOK signing — key from MOK_PRIVATE_KEY_PEM env var (GitHub Secret or VM dev key)
##############################################################################

if [[ -z "${!MOK_KEY_ENV:-}" ]]; then
    echo "[kernel] WARNING: ${MOK_KEY_ENV} not set — skipping signing (local dev build)"
else
    echo "[kernel] Signing kernel image with MOK key..."
    MOK_KEY_FILE=$(mktemp /tmp/mok-key-XXXXXX.pem)
    chmod 600 "${MOK_KEY_FILE}"
    echo "${!MOK_KEY_ENV}" > "${MOK_KEY_FILE}"
    trap 'rm -f "${MOK_KEY_FILE}"; rm -rf "${WORKDIR}"' EXIT

    sbsign \
        --key  "${MOK_KEY_FILE}" \
        --cert "${MOK_CERT}" \
        --output "arch/x86/boot/bzImage.signed" \
        "arch/x86/boot/bzImage"

    # Sign all modules
    find . -name "*.ko" | while read -r mod; do
        "${PWD}/scripts/sign-file" sha256 "${MOK_KEY_FILE}" "${MOK_CERT}" "${mod}"
    done

    rm -f "${MOK_KEY_FILE}"
    echo "[kernel] Signing complete."
fi

##############################################################################
# Install into RPM build tree
##############################################################################

echo "[kernel] Installing modules..."
make INSTALL_MOD_PATH="${WORKDIR}/installroot" modules_install

KRELEASE=$(cat include/config/kernel.release)

# Build RPM via spec
mkdir -p "${RPMBUILD_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp "${SCRIPT_DIR}/../packages/kernel-krylix.spec" "${RPMBUILD_DIR}/SPECS/"

rpmbuild -bb \
    --define "_topdir ${RPMBUILD_DIR}" \
    --define "kernel_version ${KERNEL_VERSION}" \
    --define "kernel_release ${KRELEASE}" \
    --define "source_date_epoch ${SOURCE_DATE_EPOCH}" \
    "${RPMBUILD_DIR}/SPECS/kernel-krylix.spec"

echo "[kernel] Build complete: ${RPMBUILD_DIR}/RPMS/"
echo "[kernel] Kernel version: ${KRELEASE}"
