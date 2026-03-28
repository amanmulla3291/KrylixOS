# KrylixOS — Quick Start

**Build host:** Fedora 43 Workstation · 2 CPUs · 6 GB RAM · 60 GB storage  
**Total build time:** ~90 min (kernel compile dominates at ~70 min on 2 CPUs)

---

## 1. Clone the repo

```bash
cd /home/aman
git clone https://github.com/amanmulla3291/KrylixOS.git
cd KrylixOS
```

---

## 2. One-time setup (~5 min)

Run as your regular user — **not** root:

```bash
bash vm-setup.sh
```

This installs all build dependencies, generates dev signing keys, and writes
`.env.dev`. Enter your sudo password when prompted. Safe to re-run.

---

## 3. Load the build environment

Do this at the start of **every** terminal session:

```bash
source .env.dev
```

---

## 4. Build in order

```bash
bash scripts/01-build-selinux-policy.sh   # ~2 min  — Gap 1 fix (SELinux falco_t)
bash scripts/02-build-rpms.sh             # ~3 min  — all RPM packages
bash scripts/03-build-kernel.sh           # ~70 min — Linux 6.12.y (2 CPUs, normal)
bash scripts/04-build-iso.sh             # ~15 min — bootable ISO
```

Or run everything in one shot:
```bash
bash scripts/build-all.sh
```

---

## 5. Verify

```bash
bash verify-build.sh --profile=vm --verbose
```

---

## Timing breakdown (2 CPUs)

| Step | Script | Time |
|---|---|---|
| SELinux policy | `01-build-selinux-policy.sh` | ~2 min |
| RPM packages | `02-build-rpms.sh` | ~3 min |
| Kernel 6.12.y | `03-build-kernel.sh` | **~70 min** |
| ISO | `04-build-iso.sh` | ~15 min |
| **Total** | | **~90 min** |

The 70-minute kernel compile is normal for 2 CPUs. The build runs with
`make -j2` and uses ~1.5 GB RAM at peak — well within your 6 GB.

---

## Common issues

**`vm-setup.sh` exits early:**  
It no longer uses `set -e` at the top level, so this shouldn't happen.
If it does, check the `[N/9]` step number in the output and re-run — it's idempotent.

**`source .env.dev` — file not found:**  
Run `bash vm-setup.sh` first. It writes `.env.dev` to the repo root.

**Kernel compile killed (OOM):**  
6 GB is enough, but close Firefox and other apps before starting step 3.
The peak RSS during kernel compile is ~2–2.5 GB.

**AVC denials after `01-build-selinux-policy.sh`:**  
The script will show the exact `audit2allow` output and which lines to add
to `packages/falco.te`. Add them, re-run the script, verify 0 AVCs.

---

## CI/CD (GitHub Actions)

Set up signing keys before pushing to `main`. See `SECRETS-SETUP.md`.
