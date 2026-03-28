#!/usr/bin/env bash
# migrate-domain.sh — KrylixOS Domain Migration Helper
# Run when KrylixOS.org is registered and ready to serve the DNF repo.
#
# Steps:
#   1. Register KrylixOS.org (Namecheap, Cloudflare, etc.)
#   2. Add CNAME in GitHub Pages settings: KrylixOS.org → amanmulla3291.github.io
#   3. Wait for DNS propagation (up to 48 hours)
#   4. Run this script from the repo root: bash migrate-domain.sh
#   5. Commit and push — one commit, zero structural changes needed

set -euo pipefail

OLD_DOMAIN="amanmulla3291.github.io/KrylixOS"
NEW_DOMAIN="KrylixOS.org"

echo "KrylixOS Domain Migration"
echo "  From: https://${OLD_DOMAIN}"
echo "  To:   https://${NEW_DOMAIN}"
echo ""

# Dry-run first
echo "Files that will change:"
grep -rl "${OLD_DOMAIN}" . \
    --include="*.sh" \
    --include="*.spec" \
    --include="*.yml" \
    --include="*.yaml" \
    --include="*.cfg" \
    --include="*.md" \
    --include="*.conf" \
    --include="*.ini" \
    2>/dev/null | grep -v ".git/" || echo "(none found)"

echo ""
read -rp "Proceed with migration? [y/N] " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Execute migration
find . -type f \( \
    -name "*.sh" -o \
    -name "*.spec" -o \
    -name "*.yml" -o \
    -name "*.yaml" -o \
    -name "*.cfg" -o \
    -name "*.md" -o \
    -name "*.conf" -o \
    -name "*.ini" \
\) | grep -v ".git/" | xargs sed -i \
    "s|${OLD_DOMAIN}|${NEW_DOMAIN}|g"

echo "Migration complete."
echo ""
echo "Next steps:"
echo "  1. Add CNAME file to gh-pages branch:"
echo "     echo 'KrylixOS.org' > CNAME && git add CNAME"
echo "  2. Review changes: git diff"
echo "  3. Commit: git commit -am 'chore: migrate domain to KrylixOS.org'"
echo "  4. Push: git push origin main && git push origin gh-pages"
echo "  5. Verify: curl -I https://KrylixOS.org/repo/repodata/repomd.xml"
echo "  6. Rebuild RPMs so krylix-release.spec writes new repo URL to clients"
