# KrylixOS DNF Repository

This directory is served via GitHub Pages as the KrylixOS signed RPM repository.

**Repository URL:** `https://amanmulla3291.github.io/KrylixOS/repo/`

## Client configuration

The `krylix-release` RPM writes `/etc/yum.repos.d/krylix.repo` automatically.
For manual configuration:

```ini
[krylix]
name=KrylixOS Linux Repository
baseurl=https://amanmulla3291.github.io/KrylixOS/repo/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://amanmulla3291.github.io/KrylixOS/RPM-GPG-KEY-KrylixOS
metadata_expire=6h
```

## Supply-chain hardening

- `gpgcheck=1` — verifies every RPM's signature before install
- `repo_gpgcheck=1` — verifies `repomd.xml` metadata signature (closes GitHub Pages MITM vector)
- All RPMs signed with the KrylixOS GPG key (key fingerprint in `RPM-GPG-KEY-KrylixOS`)
- `repomd.xml.asc` — detached GPG signature on repository metadata

## Packages

| Package | Description |
|---|---|
| `krylix-release` | Repo config, os-release |
| `kernel-krylix` | Hardened Linux 6.12.y (MOK-signed) |
| `selinux-krylix-policy` | SELinux falco_t domain (Gap 1 fix) |
| `falco-rules-krylix` | KrylixOS Falco eBPF rules |
| `suricata-rules-krylix` | Optional Suricata IPS rules |

## Size management

GitHub Pages has a 1 GB limit. The `update-repo.yml` workflow prunes kernel
RPMs older than the last 3 versions automatically. Current repo size is
monitored and CI fails if it exceeds 800 MB.

## Future: custom domain

When `KrylixOS.org` is registered, update GitHub Pages CNAME and run:
```bash
find . -type f | xargs sed -i 's|amanmulla3291.github.io/KrylixOS|KrylixOS.org|g'
```
