Name:           kernel-krylix
Version:        %{kernel_version}
Release:        1%{?dist}
Summary:        KrylixOS Hardened Linux Kernel %{kernel_version}
License:        GPL-2.0-only
URL:            https://github.com/amanmulla3291/KrylixOS
ExclusiveArch:  x86_64

# Reproducible builds
%global source_date_epoch_from_changelog 0
%if 0%{?source_date_epoch:1}
%global _buildhost KrylixOS
%global _buildshell /bin/bash
%endif

Requires(post):  sbsigntools
Requires(post):  dracut
Requires:        krylix-release >= 1.2
Conflicts:       kernel

%description
Hardened Linux kernel %{kernel_version} for KrylixOS Linux.
Compiled with SELinux, Falco eBPF, LUKS2, TPM2, Secure Boot (MOK),
and aggressive attack surface reduction. AWS ENA + NVMe built-in.
Suricata AF_PACKET ingress enabled (optional package).

%install
# Kernel image
install -Dm755 %{_builddir}/linux-%{kernel_version}/arch/x86/boot/bzImage.signed \
    %{buildroot}/boot/vmlinuz-%{version}-%{release}.x86_64

# System.map
install -Dm644 %{_builddir}/linux-%{kernel_version}/System.map \
    %{buildroot}/boot/System.map-%{version}-%{release}.x86_64

# Kernel config
install -Dm644 %{_builddir}/linux-%{kernel_version}/.config \
    %{buildroot}/boot/config-%{version}-%{release}.x86_64

# Modules
make -C %{_builddir}/linux-%{kernel_version} \
    INSTALL_MOD_PATH=%{buildroot} \
    INSTALL_MOD_STRIP=1 \
    modules_install

%post
set -euo pipefail

KVER="%{version}-%{release}.x86_64"
MOK_CERT="/etc/pki/krylix/KrylixOS-ca.cer"
MOK_KEY_ENV="MOK_PRIVATE_KEY_PEM"

##
## Re-sign kernel after dnf update — MOK key injected via systemd credential
## or environment variable from Vault (never stored on disk at rest)
##
if [[ -n "${!MOK_KEY_ENV:-}" && -f "${MOK_CERT}" ]]; then
    MOK_KEY_TMP=$(mktemp /tmp/.mok-XXXXXX.pem)
    chmod 600 "${MOK_KEY_TMP}"
    echo "${!MOK_KEY_ENV}" > "${MOK_KEY_TMP}"
    sbsign \
        --key  "${MOK_KEY_TMP}" \
        --cert "${MOK_CERT}" \
        --output /boot/vmlinuz-${KVER} \
        /boot/vmlinuz-${KVER}
    rm -f "${MOK_KEY_TMP}"
    echo "kernel-krylix: kernel ${KVER} signed with KrylixOS MOK key"
else
    echo "kernel-krylix: WARNING — MOK_PRIVATE_KEY_PEM not set; kernel unsigned"
    echo "  (acceptable for local dev; CI builds must have OIDC-sourced key)"
fi

## Rebuild initrd with dracut — enforce hardened modules-only load
dracut \
    --force \
    --add-drivers "dm-crypt dm-mod xts sha256 algif_hash" \
    --omit-drivers "bluetooth snd alsa" \
    --kernel-cmdline "init_on_alloc=1 init_on_free=1 vsyscall=none page_alloc.shuffle=1 security=selinux enforcing=1" \
    /boot/initramfs-${KVER}.img \
    ${KVER}

## Update GRUB2 entry
if command -v grubby &>/dev/null; then
    grubby \
        --add-kernel=/boot/vmlinuz-${KVER} \
        --initrd=/boot/initramfs-${KVER}.img \
        --title="KrylixOS Linux (${KVER})" \
        --args="init_on_alloc=1 init_on_free=1 vsyscall=none page_alloc.shuffle=1 security=selinux enforcing=1" \
        --make-default
fi

%preun
KVER="%{version}-%{release}.x86_64"
if command -v grubby &>/dev/null; then
    grubby --remove-kernel=/boot/vmlinuz-${KVER} 2>/dev/null || true
fi

%postun
KVER="%{version}-%{release}.x86_64"
rm -f /boot/vmlinuz-${KVER}
rm -f /boot/initramfs-${KVER}.img
rm -f /boot/System.map-${KVER}
rm -f /boot/config-${KVER}
rm -rf /lib/modules/${KVER}

%files
/boot/vmlinuz-%{version}-%{release}.x86_64
/boot/initramfs-%{version}-%{release}.x86_64.img
/boot/System.map-%{version}-%{release}.x86_64
/boot/config-%{version}-%{release}.x86_64
/lib/modules/%{version}-%{release}.x86_64/

%changelog
* Mon Mar 01 2026 KrylixOS Build System <build@krylix> - 6.12.0-1
- Initial KrylixOS hardened kernel package
- SELinux enforcing, Falco eBPF, LUKS2, TPM2, MODULE_SIG_FORCE
