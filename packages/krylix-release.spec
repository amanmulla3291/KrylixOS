Name:           krylix-release
Version:        1.2
Release:        1%{?dist}
Summary:        KrylixOS Linux Release Files and DNF Repository Configuration
License:        GPL-2.0-only
URL:            https://github.com/amanmulla3291/KrylixOS
BuildArch:      noarch

# Pin dnf5 version — some plugins unstable below 5.2
Requires:       dnf5 >= 5.2.0
Requires:       dnf5-plugins >= 5.2.0

# To migrate to KrylixOS.org later:
#   find . -type f | xargs sed -i 's|amanmulla3291.github.io/KrylixOS|KrylixOS.org|g'

%description
KrylixOS Linux release package. Installs:
  - /etc/yum.repos.d/krylix.repo (GitHub Pages DNF repository)
  - /etc/os-release (KrylixOS identity)
  - /etc/krylix-release
  - RPM GPG public key

Repository is hosted on GitHub Pages:
  https://amanmulla3291.github.io/KrylixOS/repo/

Supply-chain hardening:
  gpgcheck=1       — verifies individual RPM signatures
  repo_gpgcheck=1  — verifies repomd.xml metadata signature
  This closes the GitHub Pages MITM / gh-pages token compromise vector.

%install
install -Dm644 /dev/stdin %{buildroot}/etc/yum.repos.d/krylix.repo <<'REPO'
[krylix]
name=KrylixOS Linux Repository
baseurl=https://amanmulla3291.github.io/KrylixOS/repo/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://amanmulla3291.github.io/KrylixOS/RPM-GPG-KEY-KrylixOS
metadata_expire=6h
REPO

install -Dm644 /dev/stdin %{buildroot}/etc/os-release <<'OSREL'
NAME="KrylixOS Linux"
VERSION="1.2"
ID=krylix
ID_LIKE=fedora
VERSION_CODENAME=hardened
PRETTY_NAME="KrylixOS Linux 1.2 (Hardened)"
HOME_URL="https://github.com/amanmulla3291/KrylixOS"
BUG_REPORT_URL="https://github.com/amanmulla3291/KrylixOS/issues"
CPE_NAME="cpe:/o:krylix:krylix_linux:1.2"
OSREL

install -Dm644 /dev/stdin %{buildroot}/etc/krylix-release <<'REL'
KrylixOS Linux release 1.2 (Hardened)
REL

%post
# Import the GPG key into RPM keyring
rpm --import https://amanmulla3291.github.io/KrylixOS/RPM-GPG-KEY-KrylixOS 2>/dev/null || {
    echo "krylix-release: Warning — could not import GPG key (no network?)"
    echo "  Manually run: rpm --import /path/to/RPM-GPG-KEY-KrylixOS"
}

%files
%config(noreplace) /etc/yum.repos.d/krylix.repo
/etc/os-release
/etc/krylix-release

%changelog
* Mon Mar 01 2026 KrylixOS Build System <build@krylix> - 1.2-1
- v1.2: Add repo_gpgcheck=1 — closes gh-pages supply-chain vector
- dnf5 >= 5.2.0 requirement added
- GitHub Pages URL (no custom domain yet)
