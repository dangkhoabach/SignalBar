#!/bin/bash
# =============================================================================
# Release DKB Monitor for macOS.
#
# Usage: release/release.sh [patch|minor|major]   (default: patch)
#
# Bumps the version (package.json, Cargo.toml, tauri.conf.json) and builds +
# signs the macOS release into release/output/<version>/macos/.
#
# Windows is a separate step on a separate machine: see release/README.md —
# after committing + pushing the version bump here, pull this repo on the
# Windows machine and run release/build-windows.ps1 there.
#
# Uploading either platform's build anywhere is also a separate manual step
# (via admin.dangkhoabach.vn) — this script only builds.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUMP="${1:-patch}"

VERSION=$("$SCRIPT_DIR/bump-version.sh" "$BUMP")
echo "===> Version bumped to $VERSION"

"$SCRIPT_DIR/build-macos.sh" "$VERSION"

cat <<EOF

===> macOS build done (v$VERSION) -> release/output/$VERSION/macos/

Next, for a Windows build:
  1. Review the version-bump diff, then commit + push (needed so the Windows
     machine pulls the matching version):
       git diff
       git add -A && git commit -m "..."   (Release keyword, per git-rule.md)
       git push
  2. On the Windows machine: git pull, then run:
       powershell -ExecutionPolicy Bypass -File release\\build-windows.ps1
     -> produces release/output/$VERSION/windows/

See release/README.md for one-time Windows setup and how to upload both
builds via admin.dangkhoabach.vn.
EOF
