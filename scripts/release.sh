#!/usr/bin/env bash
# Builds, ad-hoc signs, DMGs, and Sparkle-signs DKB Monitor entirely on this
# machine — no CI, no GitHub Actions secrets. Same manual-release model the
# old Tauri app used (see docs/release.md): no Apple Developer Program
# membership, so no Developer ID signing and no notarization — same
# ad-hoc-signed, "right-click > Open on first launch" distribution the
# Tauri build already shipped.
#
# One-time setup (see docs/release.md):
#   - A Sparkle EdDSA keypair already generated via `generate_keys` — its
#     private half must already be in this Mac's login Keychain (sign_update
#     finds it automatically, no path/flag needed).
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="DKBMonitorApp"
PROJECT="DKBMonitorNative.xcodeproj"
APP_NAME="DKB Monitor"
INFO_PLIST="DKBMonitorApp/Info.plist"
SPARKLE_VERSION="2.6.4"
SPARKLE_TOOLS_DIR=".sparkle-tools"

echo "==> Testing DKBMonitorCore"
(cd DKBMonitorCore && swift test)

CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
read -rp "Current version is $CURRENT_VERSION (build $CURRENT_BUILD). New version [Enter to keep]: " NEW_VERSION
VERSION="${NEW_VERSION:-$CURRENT_VERSION}"
NEW_BUILD=$((CURRENT_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
echo "==> Releasing version $VERSION (build $NEW_BUILD)"

echo "==> Regenerating Xcode project"
xcodegen generate

OUT_DIR="release-output/$VERSION"
BUILD_DIR="$OUT_DIR/DerivedData"
mkdir -p "$OUT_DIR"

echo "==> Building (Release, ad-hoc signed)"
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM=""

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

echo "==> Creating DMG"
DMG_ROOT="$OUT_DIR/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP_PATH" "$DMG_ROOT/"
ln -sf /Applications "$DMG_ROOT/Applications"
DMG_PATH="$OUT_DIR/DKB-Monitor-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH"

echo "==> Signing update with Sparkle"
if [ ! -x "$SPARKLE_TOOLS_DIR/bin/sign_update" ]; then
  mkdir -p "$SPARKLE_TOOLS_DIR"
  curl -fsSL -o "$SPARKLE_TOOLS_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  tar -xf "$SPARKLE_TOOLS_DIR/sparkle.tar.xz" -C "$SPARKLE_TOOLS_DIR"
fi
# -p prints only the raw EdDSA signature (no "sparkle:edSignature=... length=..."
# wrapper) - that raw value is exactly what admin.dangkhoabach.vn's "Sparkle
# signature" upload field expects. No --account flag: this app's key was
# generated under the Keychain's default "ed25519" account (see docs/release.md).
"$SPARKLE_TOOLS_DIR/bin/sign_update" -p "$DMG_PATH" | tee "$DMG_PATH.sig"

echo ""
echo "==> Done. Upload these two files at https://admin.dangkhoabach.vn (app: dkb-monitor):"
echo "    Installer:         $DMG_PATH"
echo "    Sparkle signature:  $DMG_PATH.sig"
echo ""
echo "Reminder: this build is ad-hoc signed, not notarized (no paid Apple"
echo "Developer Program membership) - first launch needs right-click > Open"
echo "to bypass Gatekeeper, same as the old Tauri build."
