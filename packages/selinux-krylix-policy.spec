Name:           selinux-krylix-policy
Version:        1.2.0
Release:        1%{?dist}
Summary:        KrylixOS SELinux Policy — falco_t domain + system hardening
License:        GPL-2.0-only
URL:            https://github.com/amanmulla3291/KrylixOS
BuildRequires:  selinux-policy-devel
BuildRequires:  checkpolicy
BuildRequires:  policycoreutils
BuildRequires:  make
Requires:       selinux-policy-targeted
Requires:       policycoreutils
Requires:       libselinux-utils
# Gap 1 fix: must be installed before falco.service starts
Requires(pre):  policycoreutils-python-utils

%description
KrylixOS SELinux policy package. Ships the custom falco_t type enforcement
domain required for Falco eBPF operation under SELinux enforcing mode.

Without this package, Falco generates AVC storms against:
  - bpf map_create/map_read/map_write/prog_load/prog_run
  - tracefs_t read/search
  - perf_event open/cpu/kernel/tracepoint/read
  - debugfs_t, sysfs_t, proc_t reads

This package closes Gap 1 from KrylixOS spec v1.2.
Target: 0 AVC denials at steady state with Falco running.

%prep
mkdir -p %{_builddir}/selinux-krylix-policy
cp %{_sourcedir}/falco.te %{_builddir}/selinux-krylix-policy/

%build
cd %{_builddir}/selinux-krylix-policy
# Compile .te → .mod → .pp (policy package)
checkmodule -M -m -o falco.mod falco.te
semodule_package -o falco.pp -m falco.mod
echo "selinux-krylix-policy: falco.pp compiled successfully"

%install
install -Dm644 \
    %{_builddir}/selinux-krylix-policy/falco.pp \
    %{buildroot}/usr/share/selinux/targeted/falco.pp

install -Dm644 \
    %{_builddir}/selinux-krylix-policy/falco.te \
    %{buildroot}/usr/share/selinux/targeted/falco.te

%pre
# Verify SELinux is available before install
if ! selinuxenabled 2>/dev/null; then
    echo "selinux-krylix-policy: SELinux not enabled — policy will be installed but inactive"
fi

%post
set -euo pipefail

## Install the falco_t policy module
semodule -i /usr/share/selinux/targeted/falco.pp || {
    echo "selinux-krylix-policy: ERROR — semodule install failed" >&2
    exit 1
}

## Label falco executable (adjust path if falco installs elsewhere)
FALCO_BIN="/usr/bin/falco"
if [[ -f "${FALCO_BIN}" ]]; then
    semanage fcontext -a -t falco_exec_t "${FALCO_BIN}" 2>/dev/null || \
    semanage fcontext -m -t falco_exec_t "${FALCO_BIN}" 2>/dev/null || true
    restorecon -v "${FALCO_BIN}"
fi

## Label falco config dir
FALCO_CONF="/etc/falco"
if [[ -d "${FALCO_CONF}" ]]; then
    semanage fcontext -a -t falco_conf_t "${FALCO_CONF}(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t falco_conf_t "${FALCO_CONF}(/.*)?" 2>/dev/null || true
    restorecon -Rv "${FALCO_CONF}"
fi

## Label falco log dir
FALCO_LOG="/var/log/falco"
if [[ -d "${FALCO_LOG}" ]]; then
    semanage fcontext -a -t falco_var_log_t "${FALCO_LOG}(/.*)?" 2>/dev/null || true
    restorecon -Rv "${FALCO_LOG}"
fi

## Label falco run dir
FALCO_RUN="/var/run/falco"
if [[ -d "${FALCO_RUN}" ]]; then
    semanage fcontext -a -t falco_var_run_t "${FALCO_RUN}(/.*)?" 2>/dev/null || true
    restorecon -Rv "${FALCO_RUN}"
fi

echo "selinux-krylix-policy: falco_t domain installed and contexts applied"
echo "  Verify with: ausearch -m AVC | grep falco"
echo "  Target: 0 AVC denials at steady state"

%preun
if [[ $1 -eq 0 ]]; then
    # Full uninstall — remove policy module
    semodule -r falco 2>/dev/null || true
fi

%files
/usr/share/selinux/targeted/falco.pp
/usr/share/selinux/targeted/falco.te

%changelog
* Mon Mar 01 2026 KrylixOS Build System <build@krylix> - 1.2.0-1
- Initial release: falco_t SELinux domain for eBPF probe
- Closes Gap 1 from KrylixOS spec v1.2
- Covers: bpf, tracefs, debugfs, sysfs, perf_event, proc access
