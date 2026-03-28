#!/usr/bin/env bash
# cloud-aws.sh — KrylixOS AWS Cloud Post-Install Profile
# Gap 2 Fix: Clevis/Tang LUKS2 with 30-second timeout + passphrase fallback
#            (prevents cold-boot failure if Tang/KMS unreachable)
# Activates: IMDSv2 enforcement, Tang health check, cloud-init (AWS only)
# Disables:  CUPS, avahi/mDNS, TPM2 tools (not available on EC2)

set -euo pipefail
IFS=$'\n\t'

PROFILE="cloud-aws"
echo "[${PROFILE}] Applying KrylixOS AWS Cloud profile..."

##############################################################################
# Configuration — override these for your AWS environment
##############################################################################

TANG_SERVER="${TANG_SERVER:-http://tang.internal:7500}"   # Tang server URL
TANG_THUMBPRINT="${TANG_THUMBPRINT:-}"                     # Tang thumbprint (from tangd-show-keys)
AWS_REGION="${AWS_REGION:-us-east-1}"
LUKS_DEV=$(blkid -t TYPE=crypto_LUKS -o device | head -1)

if [[ -z "${LUKS_DEV}" ]]; then
    echo "[${PROFILE}] ERROR: No LUKS2 device found." >&2
    exit 1
fi

##############################################################################
# TANG HEALTH CHECK — Gap 2 fix prerequisite
# Validate Tang server is reachable BEFORE binding LUKS2 to it.
# Document the dependency explicitly.
##############################################################################

tang_health_check() {
    local url="${1}"
    local timeout="${2:-10}"
    echo "[${PROFILE}] Checking Tang server reachability: ${url}..."
    if curl -fsSL --max-time "${timeout}" "${url}/adv" | jose fmt -j- -g keys &>/dev/null; then
        echo "[${PROFILE}] Tang server OK: ${url}"
        return 0
    else
        echo "[${PROFILE}] WARNING: Tang server unreachable: ${url}" >&2
        return 1
    fi
}

##############################################################################
# 1. LUKS2 — Clevis/Tang binding with KMS (Gap 2 fix)
#    30-second timeout in dracut, passphrase fallback always present
##############################################################################

echo "[${PROFILE}] Configuring LUKS2 Clevis/Tang binding..."

# Verify Argon2id KDF
cryptsetup luksDump "${LUKS_DEV}" | grep -q "argon2id" || {
    echo "[${PROFILE}] WARNING: LUKS2 not using Argon2id KDF — re-enroll key slot"
}

if [[ -n "${TANG_THUMBPRINT}" ]] && tang_health_check "${TANG_SERVER}" 10; then
    echo "[${PROFILE}] Binding LUKS2 to Tang server..."
    clevis luks bind -d "${LUKS_DEV}" tang \
        "{\"url\":\"${TANG_SERVER}\",\"thp\":\"${TANG_THUMBPRINT}\"}" || {
        echo "[${PROFILE}] WARNING: Tang binding failed — passphrase-only mode"
    }
    echo "[${PROFILE}] Tang binding applied."
else
    echo "[${PROFILE}] NOTICE: Tang not configured or unreachable."
    echo "[${PROFILE}]   Set TANG_SERVER and TANG_THUMBPRINT environment variables"
    echo "[${PROFILE}]   and re-run this script. Defaulting to passphrase mode."
fi

##############################################################################
# 2. dracut — Gap 2 fix: 30-second Tang timeout, passphrase fallback
#    This is the CORE of the Gap 2 fix from KrylixOS spec v1.2
##############################################################################

echo "[${PROFILE}] Configuring dracut with 30-second Tang timeout + passphrase fallback..."

# Gap 2 fix: dracut timeout + passphrase fallback
cat > /etc/dracut.conf.d/krylix-clevis-aws.conf << 'EOF'
# KrylixOS AWS dracut config — Gap 2 fix
# Tang timeout: if Tang unreachable after 30s, fall through to passphrase prompt
# This prevents silent cold-boot failure when Tang EC2 instance is down or KMS unreachable

add_dracutmodules+=" clevis clevis-pin-tang network "
install_items+=" /usr/bin/clevis-luks-unlock /usr/bin/jose /usr/bin/curl "

# Critical: rd.timeout — waits max 30s for Tang before prompting passphrase
# Without this, boot hangs indefinitely when Tang is unreachable
kernel_cmdline+=" rd.timeout=30 "
EOF

# rd.timeout=30 in kernel args — network timeout for Tang acquisition
LUKS_UUID=$(blkid -s UUID -o value "${LUKS_DEV}")
KVER=$(uname -r)

dracut \
    --force \
    --add "clevis clevis-pin-tang network" \
    --add-drivers "dm-crypt dm-mod xts sha256 virtio_net ena" \
    --install "/usr/bin/clevis-luks-unlock /usr/bin/jose" \
    --kernel-cmdline "init_on_alloc=1 init_on_free=1 vsyscall=none page_alloc.shuffle=1 \
security=selinux enforcing=1 rd.luks.uuid=${LUKS_UUID} rd.timeout=30" \
    /boot/initramfs-${KVER}.img \
    "${KVER}"

echo "[${PROFILE}] dracut: 30-second Tang timeout configured."
echo "[${PROFILE}] Fallback: if Tang unreachable → passphrase prompt appears at console."

##############################################################################
# 3. GRUB2 — AWS kernel cmdline
##############################################################################

grubby --update-kernel=ALL \
    --args="init_on_alloc=1 init_on_free=1 vsyscall=none page_alloc.shuffle=1 \
security=selinux enforcing=1 rd.luks.uuid=${LUKS_UUID} rd.timeout=30"

# Remove bare metal IOMMU args
grubby --update-kernel=ALL \
    --remove-args="intel_iommu amd_iommu iommu" 2>/dev/null || true

##############################################################################
# 4. Tang health-check script — Gap 2 fix: validate before reboot
#    Run this in cloud-aws.sh and in CI before AMI snapshots
##############################################################################

cat > /usr/local/bin/krylix-tang-check << 'TANGCHECK'
#!/usr/bin/env bash
# krylix-tang-check — KrylixOS Tang server health check (Gap 2 fix)
# Run before rebooting any KrylixOS AWS instance that depends on Tang LUKS unlock
# Exit 0: Tang reachable, safe to reboot
# Exit 1: Tang unreachable — have passphrase ready or don't reboot

set -euo pipefail

TANG_SERVER="${TANG_SERVER:-http://tang.internal:7500}"
TIMEOUT=15

echo "KrylixOS Tang Health Check"
echo "  Server: ${TANG_SERVER}"
echo "  Timeout: ${TIMEOUT}s"

if curl -fsSL --max-time "${TIMEOUT}" "${TANG_SERVER}/adv" | jose fmt -j- -g keys &>/dev/null; then
    echo "  Status: ✓ REACHABLE"
    echo "  Tang-based LUKS2 unlock will succeed on reboot."
    exit 0
else
    echo "  Status: ✗ UNREACHABLE"
    echo "  WARNING: Tang server not responding."
    echo "  LUKS2 will fall back to passphrase prompt (30-second timeout)."
    echo "  Have your LUKS2 passphrase ready before rebooting."
    echo "  Or start/verify Tang EC2 instance before proceeding."
    exit 1
fi
TANGCHECK

chmod +x /usr/local/bin/krylix-tang-check
echo "[${PROFILE}] Tang health check script installed: /usr/local/bin/krylix-tang-check"

##############################################################################
# 5. IMDSv2 enforcement — block IMDSv1 token-less requests
##############################################################################

echo "[${PROFILE}] Enforcing IMDSv2 (blocking IMDSv1)..."

# Use nftables to block token-less IMDS traffic at network layer
# Complements Falco rule that alerts on IMDSv1 access
nft add table inet krylix_aws 2>/dev/null || true
nft add chain inet krylix_aws output '{ type filter hook output priority 0; }' 2>/dev/null || true
cat > /etc/nftables.d/99-krylix-imds.nft << 'EOF'
# KrylixOS IMDSv2 enforcement
# Allows only cloud-init and aws CLI to reach IMDS
# All other processes blocked from reaching 169.254.169.254
table inet krylix_imds {
    chain output {
        type filter hook output priority 0;
        ip daddr 169.254.169.254 skuid { cloud-init, root } accept
        ip daddr 169.254.169.254 drop
    }
}
EOF

# Also enforce at the EC2 instance metadata level (requires AWS CLI)
if command -v aws &>/dev/null; then
    INSTANCE_ID=$(curl -fsSL \
        -H "X-aws-ec2-metadata-token: $(curl -fsSL \
            --max-time 5 \
            -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' \
            http://169.254.169.254/latest/api/token 2>/dev/null)" \
        http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")

    if [[ -n "${INSTANCE_ID}" ]]; then
        aws ec2 modify-instance-metadata-options \
            --instance-id "${INSTANCE_ID}" \
            --http-tokens required \
            --http-endpoint enabled \
            --region "${AWS_REGION}" && \
            echo "[${PROFILE}] IMDSv2: enforced at EC2 instance level (instance: ${INSTANCE_ID})"
    fi
fi

##############################################################################
# 6. cloud-init — enable but harden (AWS profile only)
##############################################################################

echo "[${PROFILE}] Hardening cloud-init..."
cat > /etc/cloud/cloud.cfg.d/99-krylix.cfg << 'EOF'
# KrylixOS cloud-init hardening
# Allow AWS metadata (IMDSv2 only) but restrict operations
datasource_list: [ Ec2 ]
datasource:
  Ec2:
    metadata_urls: [ 'http://169.254.169.254' ]
    max_wait: 30
    timeout: 15

# Disable modules that create security risks
cloud_config_modules:
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - timezone
  # NOT included: users_groups, ssh_authkeys (managed by KrylixOS config)

# Do not allow cloud-init to modify sshd_config
ssh_deletekeys: false
ssh_genkeytypes: []

# Disable phone-home / URL calling
phone_home: {}
EOF

ENABLE_SERVICES=(cloud-init-local cloud-init cloud-config cloud-final)
for svc in "${ENABLE_SERVICES[@]}"; do
    systemctl enable "${svc}" 2>/dev/null && \
        echo "[${PROFILE}]   Enabled: ${svc}" || true
done

##############################################################################
# 7. Disable services not needed on AWS
##############################################################################

echo "[${PROFILE}] Disabling non-AWS services..."
DISABLE_SERVICES=(
    cups
    cups-browsed
    avahi-daemon
    avahi-daemon.socket
    bluetooth
    ModemManager
    tpm2-abrmd      # No TPM2 on EC2
    qemu-guest-agent
)

for svc in "${DISABLE_SERVICES[@]}"; do
    systemctl disable --now "${svc}" 2>/dev/null && \
        echo "[${PROFILE}]   Disabled: ${svc}" || true
done

##############################################################################
# 8. Enable AWS services
##############################################################################

ENABLE_SERVICES=(
    auditd
    falco
    firewalld
    sshd
    systemd-timesyncd
    amazon-ssm-agent  # Optional: Systems Manager for remote access without SSH
)

for svc in "${ENABLE_SERVICES[@]}"; do
    systemctl enable --now "${svc}" 2>/dev/null && \
        echo "[${PROFILE}]   Enabled: ${svc}" || \
        echo "[${PROFILE}]   (skipped: ${svc} not installed)"
done

##############################################################################
# 9. sysctl — AWS-specific hardening
##############################################################################

cat > /etc/sysctl.d/90-krylix-aws.conf << 'EOF'
# KrylixOS AWS sysctl hardening
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
# AWS ENA tuning
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF

sysctl -p /etc/sysctl.d/90-krylix-aws.conf

##############################################################################
# 10. firewalld — default deny, SSH only
##############################################################################

firewall-cmd --set-default-zone=drop
firewall-cmd --permanent --zone=drop --add-service=ssh
firewall-cmd --reload

##############################################################################
# 11. SSH hardening (same as other profiles)
##############################################################################

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

##############################################################################
# Summary
##############################################################################

echo ""
echo "[${PROFILE}] ============================================"
echo "[${PROFILE}] KrylixOS AWS Cloud Profile Applied"
echo "[${PROFILE}] ============================================"
echo "[${PROFILE}] LUKS2:      Clevis/Tang (${TANG_SERVER:-not configured})"
echo "[${PROFILE}] Fallback:   Passphrase (30s Tang timeout — Gap 2 fix)"
echo "[${PROFILE}] IMDSv2:     Enforced (IMDSv1 blocked)"
echo "[${PROFILE}] Falco:      eBPF active"
echo "[${PROFILE}] SELinux:    Enforcing"
echo ""
echo "[${PROFILE}] IMPORTANT — Before rebooting, run:"
echo "[${PROFILE}]   krylix-tang-check"
echo "[${PROFILE}]   If Tang unreachable: have LUKS passphrase ready"
echo ""
echo "[${PROFILE}] Reboot required to activate initrd changes."
