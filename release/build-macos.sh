#!/bin/bash
# =============================================================================
# Builds + signs the macOS release: .dmg for first-time install, plus
# .app.tar.gz + .sig for the Tauri updater. Output goes to
# release/output/<version>/macos/ — nothing is uploaded anywhere; that's a
# separate manual step, publishing all 3 files through the "Publish new app" /
# "Republish" dialog at admin.dangkhoabach.vn (macOS (Apple Silicon) row):
# installer = the .dmg, updater bundle = .app.tar.gz, signature = .sig.
# (That admin panel builds latest.json/app.json itself from those 3 files —
# nothing here needs to construct or upload a manifest.)
#
# Usage: release/build-macos.sh <version>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

VERSION="${1:?Usage: $0 <version>}"
OUT_DIR="$SCRIPT_DIR/output/$VERSION/macos"

ENV_FILE="$ROOT_DIR/.env.release"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: $ENV_FILE not found (needed to sign the updater artifacts)." >&2
    exit 1
fi

NPM="/Users/dangkhoabach/.nvm/versions/node/v24.18.0/bin/npm"
PATH="/Users/dangkhoabach/.cargo/bin:$PATH"

echo "===> [macOS] Building v$VERSION ..."
(
    cd "$ROOT_DIR"
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
    "$NPM" run tauri build
)

BUNDLE_DIR="$ROOT_DIR/src-tauri/target/release/bundle"
DMG="$BUNDLE_DIR/dmg/DKB Monitor_${VERSION}_aarch64.dmg"
TARGZ="$BUNDLE_DIR/macos/DKB Monitor.app.tar.gz"
SIG="$BUNDLE_DIR/macos/DKB Monitor.app.tar.gz.sig"

for f in "$DMG" "$TARGZ" "$SIG"; do
    [[ -f "$f" ]] || { echo "Error: expected build output not found: $f" >&2; exit 1; }
done

mkdir -p "$OUT_DIR"
cp "$DMG" "$OUT_DIR/DKB.Monitor_${VERSION}_aarch64.dmg"
cp "$TARGZ" "$OUT_DIR/DKB.Monitor_aarch64.app.tar.gz"
cp "$SIG" "$OUT_DIR/DKB.Monitor_aarch64.app.tar.gz.sig"

echo "  ✓ macOS build ready → $OUT_DIR"
echo "    - DKB.Monitor_${VERSION}_aarch64.dmg     -> Installer file"
echo "    - DKB.Monitor_aarch64.app.tar.gz         -> Updater bundle"
echo "    - DKB.Monitor_aarch64.app.tar.gz.sig     -> Signature (.sig)"
echo "  Upload all 3 at admin.dangkhoabach.vn, macOS (Apple Silicon) row."
