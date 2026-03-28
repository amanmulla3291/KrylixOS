#!/usr/bin/env bash
# vm.sh — KrylixOS Virtual Machine Post-Install Profile
# Activates: Passphrase LUKS2 (no TPM2 dependency), virtio-rng entropy seeding
# Disables: TPM2 tools, AWS metadata agent, IOMMU (not needed in VM)

set -euo pipefail
IFS=$'\n\t'

PROFILE="vm"
echo "[${PROFILE}] Applying KrylixOS VM profile..."

##############################################################################
# 1. LUKS2 — passphrase mode (no TPM2 in hypervisor environments)
#    Passphrase prompt appears at boot from hypervisor console
##############################################################################

echo "[${PROFILE}] Verifying LUKS2 passphrase mode..."
LUKS_DEV=$(blkid -t TYPE=crypto_LUKS -o device | head -1)
if [[ -z "${LUKS_DEV}" ]]; then
    echo "[${PROFILE}] ERROR: No LUKS2 device found." >&2
    exit 1
fi

# Verify Argon2id KDF is set (should be from installer — assert here)
cryptsetup luksDump "${LUKS_DEV}" | grep -q "argon2id" || {
    echo "[${PROFILE}] WARNING: LUKS2 device not using Argon2id KDF"
    echo "[${PROFILE}]   Re-add key with: cryptsetup luksChangeKey --pbkdf argon2id"
    echo "[${PROFILE}]   Recommended: --pbkdf-memory=1048576 --pbkdf-parallel=4 --pbkdf-force-iterations=4"
}

# Ensure no Clevis/TPM2 binding (unnecessary in VM, remove if present)
clevis luks list -d "${LUKS_DEV}" 2>/dev/null | grep -q "tpm2" && {
    echo "[${PROFILE}] Removing unexpected TPM2 binding from VM LUKS device..."
    clevis luks unbind -d "${LUKS_DEV}" -s 1 -f 2>/dev/null || true
}

echo "[${PROFILE}] LUKS2 passphrase mode confirmed."

##############################################################################
# 2. dracut — rebuild initrd (no TPM2/Clevis, include virtio drivers)
##############################################################################

KVER=$(uname -r)
echo "[${PROFILE}] Rebuilding initrd for VM (virtio, no TPM2)..."
dracut \
    --force \
    --add-drivers "dm-crypt dm-mod xts sha256 virtio_blk virtio_net virtio_rng hw_random" \
    --omit "clevis clevis-pin-tpm2 tpm2-tools" \
    --kernel-cmdline "init_on_alloc=1 init_on_free=1 vsyscall=none page_alloc.shuffle=1 security=selinux enforcing=1 rd.luks.uuid=$(blkid -s UUID -o value ${LUKS_DEV})" \
    /boot/initramfs-${KVER}.img \
    "${KVER}"

##############################################################################
# 3. GRUB2 — VM kernel cmdline (no IOMMU)
##############################################################################

echo "[${PROFILE}] Setting kernel cmdline for VM..."
grubby --update-kernel=ALL \
    --args="init_on_alloc=1 init_on_free=1 vsyscall=none page_alloc.shuffle=1 \
security=selinux enforcing=1 \
rd.luks.uuid=$(blkid -s UUID -o value ${LUKS_DEV})"

# Remove IOMMU args if set from a previous bare metal profile run
grubby --update-kernel=ALL \
    --remove-args="intel_iommu amd_iommu iommu" 2>/dev/null || true

##############################################################################
# 4. virtio-rng — seed entropy from hypervisor RNG
#    Prevents low-entropy condition at boot (important for crypto ops)
##############################################################################

echo "[${PROFILE}] Configuring virtio-rng entropy seeding..."
modprobe virtio_rng 2>/dev/null || true
modprobe hw_random 2>/dev/null || true

# Ensure rngd or systemd-random-seed uses virtio source
cat > /etc/systemd/system/krylix-virtio-rng.service << 'EOF'
[Unit]
Description=KrylixOS virtio-rng entropy seeder
DefaultDependencies=no
Before=sysinit.target
ConditionVirtualization=vm

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'cat /dev/hwrng > /dev/urandom 2>/dev/null || true'
ExecStart=/bin/sh -c 'dd if=/dev/hwrng of=/dev/urandom bs=512 count=1 2>/dev/null || true'

[Install]
WantedBy=sysinit.target
EOF

systemctl daemon-reload
systemctl enable krylix-virtio-rng.service

##############################################################################
# 5. Disable bare-metal / cloud-specific services
##############################################################################

echo "[${PROFILE}] Disabling non-VM services..."
DISABLE_SERVICES=(
    tpm2-abrmd
    cloud-init
    cloud-init-local
    cloud-config
    cloud-final
    # AWS metadata services
)

for svc in "${DISABLE_SERVICES[@]}"; do
    systemctl disable --now "${svc}" 2>/dev/null && \
        echo "[${PROFILE}]   Disabled: ${svc}" || true
done

##############################################################################
# 6. Enable VM profile services
##############################################################################

echo "[${PROFILE}] Enabling VM services..."
ENABLE_SERVICES=(
    auditd
    falco
    firewalld
    sshd
    systemd-timesyncd
    qemu-guest-agent     # Optional: enables live snapshots with consistent state
)

for svc in "${ENABLE_SERVICES[@]}"; do
    systemctl enable --now "${svc}" 2>/dev/null && \
        echo "[${PROFILE}]   Enabled: ${svc}" || \
        echo "[${PROFILE}]   (skipped: ${svc} not installed)"
done

##############################################################################
# 7. sysctl — VM hardening (same base as bare metal, minus TPM/IOMMU tweaks)
##############################################################################

cat > /etc/sysctl.d/90-krylix-vm.conf << 'EOF'
# KrylixOS VM sysctl hardening
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_regular = 2
fs.protected_fifos = 2
fs.suid_dumpable = 0
dev.tty.ldisc_autoload = 0
EOF

sysctl -p /etc/sysctl.d/90-krylix-vm.conf

##############################################################################
# 8. firewalld + PAM + SSH (same as bare metal)
##############################################################################

firewall-cmd --set-default-zone=drop
firewall-cmd --permanent --zone=drop --add-service=ssh
firewall-cmd --reload

authselect select hardening with-faillock --force
sed -i 's/deny = .*/deny = 5/' /etc/security/faillock.conf
sed -i 's/unlock_time = .*/unlock_time = 900/' /etc/security/faillock.conf

cat > /etc/ssh/sshd_config.d/99-krylix.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

systemctl reload sshd

echo ""
echo "[${PROFILE}] ============================================"
echo "[${PROFILE}] KrylixOS VM Profile Applied"
echo "[${PROFILE}] ============================================"
echo "[${PROFILE}] LUKS2:      Passphrase (no TPM2)"
echo "[${PROFILE}] Entropy:    virtio-rng seeded"
echo "[${PROFILE}] Falco:      eBPF active"
echo "[${PROFILE}] SELinux:    Enforcing"
echo "[${PROFILE}] Reboot required to activate initrd changes."
echo "[${PROFILE}] At next boot: enter LUKS2 passphrase at console."
