#!/usr/bin/env bash
# Builds, signs, notarizes, DMGs, and Sparkle-signs DKB Monitor entirely on
# this machine — no CI, no GitHub Actions secrets. Same manual-release model
# the old Tauri app used (see docs/release.md), adapted to Xcode/Sparkle.
#
# One-time setup (see docs/release.md):
#   - A "Developer ID Application" signing identity in this Mac's Keychain.
#   - `xcrun notarytool store-credentials` run once to save an App Store
#     Connect API key under a keychain profile (default name below).
#   - A Sparkle EdDSA keypair already generated via `generate_keys` — its
#     private half must already be in this Mac's login Keychain (sign_update
#     finds it automatically, no path/flag needed).
#   - export APPLE_TEAM_ID=XXXXXXXXXX in your shell profile.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="DKBMonitorApp"
PROJECT="DKBMonitorNative.xcodeproj"
APP_NAME="DKB Monitor"
INFO_PLIST="DKBMonitorApp/Info.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-dkb-release-notarize}"
SPARKLE_VERSION="2.6.4"
SPARKLE_TOOLS_DIR=".sparkle-tools"

: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID (your Apple Developer Team ID) in your shell env before running this script}"

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
mkdir -p "$OUT_DIR"
ARCHIVE_PATH="$OUT_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$OUT_DIR/export"

echo "==> Archiving"
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID"

echo "==> Exporting"
cat > "$OUT_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OUT_DIR/exportOptions.plist"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"

echo "==> Notarizing (this can take a few minutes)"
ditto -c -k --keepParent "$APP_PATH" "$OUT_DIR/$APP_NAME.zip"
xcrun notarytool submit "$OUT_DIR/$APP_NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"

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
