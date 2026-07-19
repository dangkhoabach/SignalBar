#!/bin/bash
# =============================================================================
# Release DKB Monitor for macOS.
#
# Usage: release/release.sh
#
# Prompts for which version to release (shows the current one, Enter keeps
# it unchanged — no auto-bump), then builds + signs the macOS release into
# release/output/<version>/macos/.
#
# Windows is a separate step on a separate machine: see release/README.md —
# after committing + pushing here, pull this repo on the Windows machine and
# run release/build-windows.ps1 there (same version, since it just builds
# whatever's checked out).
#
# Uploading either platform's build anywhere is also a separate manual step
# (via admin.dangkhoabach.vn) — this script only builds.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CURRENT=$(grep -m1 '"version"' "$ROOT_DIR/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/')
read -r -p "Current version: $CURRENT — release version? [$CURRENT]: " INPUT
VERSION="${INPUT:-$CURRENT}"

VERSION=$("$SCRIPT_DIR/set-version.sh" "$VERSION")

"$SCRIPT_DIR/build-macos.sh" "$VERSION"

cat <<EOF

===> macOS build done (v$VERSION) -> release/output/$VERSION/macos/

Next, for a Windows build:
  1. If the version changed, review the diff and commit + push (needed so
     the Windows machine pulls the matching version):
       git diff
       git add -A && git commit -m "..."   (Release keyword, per git-rule.md)
       git push
  2. On the Windows machine: git pull, then run:
       powershell -ExecutionPolicy Bypass -File release\\build-windows.ps1
     -> produces release/output/$VERSION/windows/

See release/README.md for one-time Windows setup and how to upload both
builds via admin.dangkhoabach.vn.
EOF
