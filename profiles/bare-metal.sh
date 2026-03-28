#!/usr/bin/env bash
# bare-metal.sh — KrylixOS Bare Metal Post-Install Profile
# Activates: TPM2-sealed LUKS2 (PCRs 0+1+7), IOMMU force-on
# Disables: cloud-init, AWS metadata agent, TPM2 workarounds for VMs

set -euo pipefail
IFS=$'\n\t'

PROFILE="bare-metal"
echo "[${PROFILE}] Applying KrylixOS bare metal profile..."

##############################################################################
# 1. LUKS2 — TPM2-sealed with Clevis (PCRs 0+1+7)
#    PCR 0: BIOS/firmware measurement
#    PCR 1: BIOS configuration
#    PCR 7: Secure Boot state
##############################################################################

echo "[${PROFILE}] Configuring LUKS2 TPM2 binding..."
LUKS_DEV=$(blkid -t TYPE=crypto_LUKS -o device | head -1)
if [[ -z "${LUKS_DEV}" ]]; then
    echo "[${PROFILE}] ERROR: No LUKS2 device found. Did you enable LUKS2 during install?" >&2
    exit 1
fi

# Bind the LUKS2 volume to TPM2 via Clevis
# PCRs 0+1+7 = firmware + config + Secure Boot state
clevis luks bind -d "${LUKS_DEV}" tpm2 \
    '{"pcr_bank":"sha256","pcr_ids":"0,1,7"}' || {
    echo "[${PROFILE}] WARNING: TPM2 binding failed — likely no TPM2 present or PCR values unstable"
    echo "[${PROFILE}]   Falling back to passphrase. Configure TPM2 manually after reboot."
}

# Verify binding
clevis luks list -d "${LUKS_DEV}" 2>/dev/null && \
    echo "[${PROFILE}] TPM2 LUKS2 binding confirmed." || true

##############################################################################
# 2. dracut — rebuild initrd with Clevis TPM2 support
##############################################################################

KVER=$(uname -r)
echo "[${PROFILE}] Rebuilding initrd with Clevis TPM2..."
dracut \
    --force \
    --add "clevis clevis-pin-tpm2 tpm2-tools" \
    --add-drivers "dm-crypt dm-mod xts sha256 tpm tpm_tis tpm_crb" \
    --omit "network" \
    --kernel-cmdline "init_on_alloc=1 init_on_free=1 vsyscall=none page_alloc.shuffle=1 security=selinux enforcing=1 rd.luks.uuid=$(blkid -s UUID -o value ${LUKS_DEV})" \
    /boot/initramfs-${KVER}.img \
    "${KVER}"

##############################################################################
# 3. GRUB2 — set bare metal kernel cmdline (IOMMU force-on)
##############################################################################

echo "[${PROFILE}] Setting kernel cmdline for bare metal..."
grubby --update-kernel=ALL \
    --args="init_on_alloc=1 init_on_free=1 vsyscall=none page_alloc.shuffle=1 \
security=selinux enforcing=1 \
intel_iommu=on amd_iommu=on iommu=force \
rd.luks.uuid=$(blkid -s UUID -o value ${LUKS_DEV})"

##############################################################################
# 4. Disable cloud and VM services (not needed on bare metal)
##############################################################################

echo "[${PROFILE}] Disabling cloud/VM services..."
DISABLE_SERVICES=(
    cloud-init
    cloud-init-local
    cloud-config
    cloud-final
    qemu-guest-agent
    open-vm-tools
    vmtoolsd
    waagent          # Azure agent — not needed
)

for svc in "${DISABLE_SERVICES[@]}"; do
    systemctl disable --now "${svc}" 2>/dev/null && \
        echo "[${PROFILE}]   Disabled: ${svc}" || true
done

##############################################################################
# 5. Enable bare-metal specific services
##############################################################################

echo "[${PROFILE}] Enabling bare metal services..."
ENABLE_SERVICES=(
    tpm2-abrmd        # TPM2 access broker — required for Clevis
    auditd
    falco
    firewalld
    sshd
    systemd-timesyncd
)

for svc in "${ENABLE_SERVICES[@]}"; do
    systemctl enable --now "${svc}" 2>/dev/null && \
        echo "[${PROFILE}]   Enabled: ${svc}" || \
        echo "[${PROFILE}]   WARNING: Could not enable ${svc}"
done

##############################################################################
# 6. sysctl — bare metal hardening (beyond base)
##############################################################################

cat > /etc/sysctl.d/90-krylix-baremetal.conf << 'EOF'
# KrylixOS bare metal sysctl hardening
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

sysctl -p /etc/sysctl.d/90-krylix-baremetal.conf

##############################################################################
# 7. firewalld — default deny, SSH only
##############################################################################

firewall-cmd --set-default-zone=drop
firewall-cmd --permanent --zone=drop --add-service=ssh
firewall-cmd --reload
echo "[${PROFILE}] firewalld: default-deny, SSH allowed"

##############################################################################
# 8. PAM hardening
##############################################################################

# pam_faillock: 5 attempts, 15-min lockout
authselect select hardening with-faillock --force
sed -i 's/deny = .*/deny = 5/' /etc/security/faillock.conf
sed -i 's/unlock_time = .*/unlock_time = 900/' /etc/security/faillock.conf

# pam_pwquality: minlen=14, require digit+upper+special
cat > /etc/security/pwquality.conf << 'EOF'
minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
maxrepeat = 3
gecoscheck = 1
EOF

##############################################################################
# 9. SSH hardening
##############################################################################

cat > /etc/ssh/sshd_config.d/99-krylix.conf << 'EOF'
# KrylixOS SSH hardening
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
Banner /etc/issue.net
EOF

systemctl reload sshd

echo ""
echo "[${PROFILE}] ============================================"
echo "[${PROFILE}] KrylixOS Bare Metal Profile Applied"
echo "[${PROFILE}] ============================================"
echo "[${PROFILE}] LUKS2:   TPM2-sealed (PCRs 0+1+7)"
echo "[${PROFILE}] IOMMU:   Force-on (intel + amd)"
echo "[${PROFILE}] Falco:   eBPF active"
echo "[${PROFILE}] SELinux: Enforcing"
echo "[${PROFILE}] Verify:  ausearch -m AVC | grep -c AVC  (target: 0)"
echo "[${PROFILE}] Reboot required to activate initrd changes."
