# KrylixOS — GitHub Secrets Setup Guide

This guide sets up the three secrets required for CI/CD signing.  
Do this **once**, before pushing to `main` for the first time.

---

## Secrets Required

| Secret Name | What it is | Used by |
|---|---|---|
| `MOK_PRIVATE_KEY_PEM` | RSA-4096 private key (PEM) for kernel signing | `build-kernel.yml` |
| `MOK_CERT_PEM` | X.509 certificate matching the MOK key | `build-kernel.yml` |
| `GPG_PRIVATE_KEY` | ASCII-armored GPG private key for RPM/repo signing | `build-rpms.yml`, `update-repo.yml` |
| `GPG_PASSPHRASE` | Passphrase for the GPG key (can be empty) | `build-rpms.yml`, `update-repo.yml` |

---

## Step 1 — Generate the MOK Keypair (Secure Boot signing)

Run this **once** on your Fedora 43 Workstation.  
Store the output files somewhere safe — you will need them to enroll the cert at install time.

```bash
# Generate MOK key + cert (10-year validity — rotate on major release)
openssl req -newkey rsa:4096 \
  -nodes \
  -keyout KrylixOS-mok.key \
  -new -x509 \
  -sha256 \
  -days 3650 \
  -subj "/CN=KrylixOS MOK Signing Key/" \
  -out KrylixOS-mok.cer

# Verify
openssl x509 -in KrylixOS-mok.cer -noout -subject -dates
```

---

## Step 2 — Generate the GPG Keypair (RPM + repo signing)

```bash
# Interactive key generation — choose RSA 4096, no expiry (or 2 years)
gpg --full-gen-key

# List keys to find your key ID
gpg --list-keys --keyid-format LONG

# Export private key (this goes into GitHub Secret)
gpg --armor --export-secret-keys YOUR_KEY_ID > KrylixOS-gpg-private.asc

# Export public key (this goes into repo/RPM-GPG-KEY-KrylixOS on gh-pages)
gpg --armor --export YOUR_KEY_ID > repo/RPM-GPG-KEY-KrylixOS
```

---

## Step 3 — Add Secrets to GitHub

Go to your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add each secret:

### `MOK_PRIVATE_KEY_PEM`
```
Contents of KrylixOS-mok.key (the entire file including -----BEGIN...-----END-----)
```

### `MOK_CERT_PEM`
```
Contents of KrylixOS-mok.cer (the entire file including -----BEGIN CERTIFICATE----- header)
```

### `GPG_PRIVATE_KEY`
```
Contents of KrylixOS-gpg-private.asc (the entire ASCII-armored export)
```

### `GPG_PASSPHRASE`
```
The passphrase you set when generating the GPG key.
Leave empty (blank secret) if you chose no passphrase.
```

---

## Step 4 — Add the GPG Public Key to your repo

The public key must be committed to `repo/` so clients can verify packages:

```bash
gpg --armor --export YOUR_KEY_ID > repo/RPM-GPG-KEY-KrylixOS
git add repo/RPM-GPG-KEY-KrylixOS
git commit -m "chore: add GPG public key for RPM verification"
git push
```

---

## Step 5 — Enroll the MOK cert at install time

When installing KrylixOS on a bare metal machine:

```bash
# On the target machine (after booting KrylixOS installer)
sudo mokutil --import KrylixOS-mok.cer
# → Reboot → MOK manager appears → Enroll MOK → reboot
```

The Kickstart `ks.cfg` handles this automatically during profile activation.

---

## Security notes

- **Never commit** `KrylixOS-mok.key` or `KrylixOS-gpg-private.asc` to the repo.
- The `.gitignore` below blocks accidental commits:

```gitignore
# .gitignore — add these lines
*.key
*-private.asc
*-private.gpg
.env.dev
```

- For higher security later: migrate from GitHub Secrets to HashiCorp Vault with OIDC.
  The workflows are already structured to make this a drop-in change —
  replace `${{ secrets.MOK_PRIVATE_KEY_PEM }}` with `${{ env.MOK_PRIVATE_KEY_PEM }}`
  and add the `vault-action` step back in.

---

## Verify secrets are working

After pushing secrets, trigger the workflows manually:

```
GitHub → Actions → "Build RPM Packages" → Run workflow
```

If you see `✓ GPG key ready` and `✓ All RPMs signed` in the log, secrets are configured correctly.
