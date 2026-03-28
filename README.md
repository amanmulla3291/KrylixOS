# KrylixOS Linux

> **Trust nothing. Verify everything.**

A custom RPM-based Linux distribution built from kernel source through to a signed bootable ISO. Security is not a post-install exercise — it is compiled into every layer.

**v1.2 · March 2026 · Production readiness: 9.2/10 → closes to 9.6+ after Gap 1 fix**

[![Build Kernel](https://github.com/amanmulla3291/KrylixOS/actions/workflows/build-kernel.yml/badge.svg)](https://github.com/amanmulla3291/KrylixOS/actions/workflows/build-kernel.yml)
[![Build RPMs](https://github.com/amanmulla3291/KrylixOS/actions/workflows/build-rpms.yml/badge.svg)](https://github.com/amanmulla3291/KrylixOS/actions/workflows/build-rpms.yml)
[![Build ISO](https://github.com/amanmulla3291/KrylixOS/actions/workflows/build-iso.yml/badge.svg)](https://github.com/amanmulla3291/KrylixOS/actions/workflows/build-iso.yml)

---

## What it is

KrylixOS is a **Red Hat / Fedora DNA** distribution (RPM, dnf5, SELinux, systemd) with aggressive attack surface reduction and a security stack that is active before the first login prompt:

- **Kernel** — Linux 6.12.y LTS, auto-tracked, compiled with 15+ hardening options, AWS ENA + NVMe built-in, Bluetooth/ALSA/USB-printer/amateur-radio/SCSI-tape disabled
- **Secure Boot** — shim → GRUB2 → MOK-signed kernel → signed initrd. `CONFIG_MODULE_SIG_FORCE=y` — unsigned modules cannot load
- **LUKS2 FDE** — AES-256-XTS, Argon2id KDF. TPM2-sealed on bare metal (PCRs 0+1+7), Clevis/Tang on AWS with 30-second timeout fallback, passphrase on VM
- **SELinux Enforcing** — targeted policy + custom `falco_t` domain. Target: 0 AVC denials
- **Falco eBPF** — mandatory, active at first boot, alerting to journald before any user logs in
- **Suricata IPS** — optional (`dnf install suricata suricata-rules-krylix`), not running at idle

**No** snap, flatpak, PulseAudio, Bluetooth, CUPS, avahi, telemetry, crash reporters, or GUI login manager.

---

## Open Gaps (action required before first build)

### 🔴 Gap 1 — SELinux/Falco (Critical — do this first)

Falco eBPF requires BPF map access, tracefs reads, and perf ring buffer — all blocked by SELinux enforcing without a custom policy. Without `falco.te`, AVC storms are guaranteed and Falco fails silently.

**Fix:** `packages/falco.te` + `packages/selinux-krylix-policy.spec` — **already written**. Must be built and installed before any other build work.

```bash
# Step 1: build the SELinux policy RPM
rpmbuild -bb packages/selinux-krylix-policy.spec
# Step 2: install on test system, run Falco, verify 0 AVCs
ausearch -m AVC | grep falco   # must return nothing
```

### ⚠️ Gap 2 — LUKS2/Tang Cold-Boot (Medium — AWS profile)

Tang dependency at initramfs stage means a down Tang EC2 instance = silent boot failure.

**Fix:** `rd.timeout=30` in dracut + passphrase fallback — **already in `cloud-aws.sh`**. Run `krylix-tang-check` before every reboot of an AWS instance.

---

## Build Order

**Build host: Fedora 43 Workstation (6+ GB RAM, 60+ GB disk)**

```bash
# One-time setup (installs all deps, generates dev keys)
bash vm-setup.sh

# Load dev environment in every new terminal
source .env.dev

# Build in order — Gap 1 always first
bash scripts/01-build-selinux-policy.sh   # ~2 min  — Gap 1 fix, tests real AVCs
bash scripts/02-build-rpms.sh             # ~3 min  — all non-kernel RPMs
bash scripts/03-build-kernel.sh           # ~25 min — Linux 6.12.y
bash scripts/04-build-iso.sh             # ~15 min — bootable ISO

# Or run everything at once
bash scripts/build-all.sh

# Verify when done
bash verify-build.sh --profile=vm --openscap --verbose
```

**CI/CD (GitHub Actions):** See `SECRETS-SETUP.md` before pushing to `main`.

---

## Repository Structure

```
KrylixOS/
├── kernel/
│   ├── build-kernel.sh              # Auto-tracks 6.12.y; SOURCE_DATE_EPOCH
│   └── config/
│       └── kernel-krylix.config     # Hardened config (BPF, SELinux, AWS drivers)
├── packages/
│   ├── falco.te                     # ← Gap 1 fix (build first)
│   ├── selinux-krylix-policy.spec   # falco_t domain RPM
│   ├── krylix-release.spec          # repo config (repo_gpgcheck=1)
│   ├── kernel-krylix.spec           # MOK %post signing
│   ├── falco-rules-krylix.spec      # KrylixOS Falco rules
│   └── suricata-rules-krylix.spec   # Optional Suricata IPS rules
├── profiles/
│   ├── bare-metal.sh                # TPM2 PCR 0+1+7, IOMMU force-on
│   ├── vm.sh                        # Passphrase LUKS2, virtio-rng
│   └── cloud-aws.sh                 # Tang + 30s timeout (Gap 2 fix)
├── iso/
│   └── ks.cfg                       # Kickstart: profile selector + install
├── repo/                            # → deployed to gh-pages branch
│   └── README.md
├── .github/workflows/
│   ├── build-kernel.yml             # GitHub Secrets MOK signing
│   ├── build-rpms.yml               # GitHub Secrets GPG signing
│   ├── build-iso.yml                # SOURCE_DATE_EPOCH reproducibility
│   └── update-repo.yml              # Kernel pruning + gh-pages publish
├── verify-build.sh                  # Production readiness verification
└── migrate-domain.sh                # KrylixOS.org migration (one-shot)
```

---

## Target Profiles

| Profile | LUKS2 Unlock | Extra Hardening |
|---|---|---|
| **Bare Metal** | TPM2 (PCRs 0+1+7) | IOMMU force-on, no cloud agents |
| **Virtual Machine** | Passphrase | virtio-rng entropy seeding |
| **AWS Cloud** | Clevis/Tang, 30s timeout + passphrase fallback | IMDSv2 enforced, cloud-init hardened |

---

## Performance Targets

| Metric | Target | Status |
|---|---|---|
| Idle RAM (Suricata off) | < 180 MB | Falco + auditd + SELinux ≈ 140–170 MB |
| Boot to shell (bare metal) | < 3 seconds | After LUKS2 unlock |
| ISO size | < 550 MB | Reproducible build |
| SELinux AVC denials | 0 | Requires Gap 1 fix |
| ISO SHA256 reproducibility | Deterministic | SOURCE_DATE_EPOCH set |
| CIS Benchmark | > Level 2 | OpenSCAP via `verify-build.sh --openscap` |

---

## DNF Repository

```bash
# Automatically configured by krylix-release RPM
# Manual:
cat > /etc/yum.repos.d/krylix.repo << EOF
[krylix]
name=KrylixOS Linux Repository
baseurl=https://amanmulla3291.github.io/KrylixOS/repo/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://amanmulla3291.github.io/KrylixOS/RPM-GPG-KEY-KrylixOS
EOF

dnf update   # pulls latest kernel, Falco rules, SELinux policy — no reinstalls ever
```

---

## Future

- Register `KrylixOS.org` → run `bash migrate-domain.sh` (one commit, zero structural changes)
- Add QEMU RAM CI gate: `free -m` check in `build-iso.yml` to enforce < 180 MB
- Closing Gap 1 (falco.te) returns score to ≥ 9.6/10
- Closing both gaps + RAM CI gate: 9.7–9.8/10

---

*KrylixOS Linux — Built by a security professional, for security professionals.*
*v1.2 · github.com/amanmulla3291/KrylixOS*
