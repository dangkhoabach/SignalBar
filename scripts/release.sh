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
#   - `brew install create-dmg` (styles the installer DMG's Finder window -
#     icon layout + Applications drop link - instead of hdiutil's bare copy).
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="DKBMonitorApp"
PROJECT="DKBMonitorNative.xcodeproj"
APP_NAME="DKB Monitor"
INFO_PLIST="DKBMonitorApp/Info.plist"
SPARKLE_VERSION="2.6.4"
SPARKLE_TOOLS_DIR=".sparkle-tools"

command -v create-dmg >/dev/null || { echo "Error: create-dmg not found. Run: brew install create-dmg" >&2; exit 1; }

echo "==> Testing DKBMonitorCore"
(cd DKBMonitorCore && swift test)

# The Core suite alone let a release ship with the app target's own tests
# never run — the view models, cleanup and scanner live there.
echo "==> Testing DKBMonitorApp"
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination "platform=macOS" -quiet

# Info.plist is the source of truth for the version.
#
# Both CFBundleShortVersionString and CFBundleVersion get set to the exact
# same MAJOR.MINOR.PATCH string the user enters here, matching the
# sparkle:version/sparkle:shortVersionString pair admin.dangkhoabach.vn's
# upload form writes into the appcast. An earlier version of this script
# split the input into a 2-component marketing version plus a separate
# build number (e.g. "2.0.1" -> version "2.0", build "1") - typing "2.0.1"
# for a second release produced the exact same CFBundleVersion ("1") as the
# very first "2.0" release, so Sparkle could never tell the two apart and
# kept reporting an update as available even once the user was already on
# the latest DMG.
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
SUGGESTED_VERSION=$(awk -F. '{print $1"."$2"."$3+1}' <<< "$CURRENT_VERSION")
read -rp "Current version is $CURRENT_VERSION. New version (e.g. $SUGGESTED_VERSION) [Enter to keep]: " INPUT
VERSION="${INPUT:-$CURRENT_VERSION}"

# The version goes into a PlistBuddy command and ends up in a filename, so
# anything but three plain numbers is rejected before it can do damage: a
# path separator would write the DMG somewhere unintended.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Error: version must be MAJOR.MINOR.PATCH (digits only), got \"$VERSION\"." >&2
  exit 1
}

# Sparkle decides "is there an update" by comparing versions, so shipping a
# lower number than what is already published leaves every existing install
# quietly stuck — no error anywhere, just an update nobody is ever offered.
if [ "$VERSION" != "$CURRENT_VERSION" ] &&
   [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
  echo "Error: $VERSION is lower than the current $CURRENT_VERSION." >&2
  exit 1
fi

# Info.plist is edited in place before the build, so any failure from here
# on would otherwise leave it bumped — and the next run would read that
# abandoned number as the current version and refuse to reuse it.
INFO_PLIST_BACKUP=$(mktemp)
cp "$INFO_PLIST" "$INFO_PLIST_BACKUP"

# One handler, installed once: `$?` inside a trap is whatever ran last, so
# chaining two traps would have the second read the first's exit code
# instead of the script's and never restore anything.
on_exit() {
  local status=$?
  if [ -n "${BUILD_DIR:-}" ]; then
    rm -rf "$BUILD_DIR"
  fi
  if [ "$status" -ne 0 ]; then
    echo "==> Failed (exit $status) — restoring $INFO_PLIST" >&2
    cp "$INFO_PLIST_BACKUP" "$INFO_PLIST"
  fi
  rm -f "$INFO_PLIST_BACKUP"
}
trap on_exit EXIT

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST"
echo "==> Releasing version $VERSION"

OUT_DIR="release-output/$VERSION"
mkdir -p "$OUT_DIR"

# Outside release-output, and removed on the way out. Keeping DerivedData
# next to the DMG meant every release left roughly a gigabyte behind — five
# releases had accumulated 5GB of build intermediates alongside 5 DMGs that
# together are a rounding error. The DMG and its signature are the only two
# files worth keeping.
BUILD_DIR=$(mktemp -d)

echo "==> Building (Release, ad-hoc signed, universal arm64+x86_64)"
# Without an explicit -destination, xcodebuild resolves the implicit "My
# Mac" destination and only builds for that Mac's own architecture,
# ignoring the project's ARCHS setting - producing an arm64-only binary on
# an Apple Silicon build machine, unusable on Intel Macs. The generic
# platform destination makes it build for every arch in ARCHS instead.
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination "generic/platform=macOS" -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM=""

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

# Everything below packages and signs whatever sits at APP_PATH without ever
# looking at it. A build that silently produced nothing, or produced an
# arm64-only binary, still yielded a DMG with a valid EdDSA signature — one
# that simply doesn't launch on the Macs it was meant for.
echo "==> Verifying the built app"
[ -d "$APP_PATH" ] || { echo "Error: no app at $APP_PATH — the build produced nothing." >&2; exit 1; }

codesign --verify --deep --strict "$APP_PATH" || {
  echo "Error: $APP_PATH failed signature verification." >&2
  exit 1
}

ARCHS_BUILT=$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")
for arch in arm64 x86_64; do
  grep -qw "$arch" <<< "$ARCHS_BUILT" || {
    echo "Error: binary is missing $arch (built: $ARCHS_BUILT). Intel or Apple Silicon Macs would be left out." >&2
    exit 1
  }
done
echo "    architectures: $ARCHS_BUILT"

echo "==> Creating DMG"
DMG_PATH="$OUT_DIR/DKB-Monitor-$VERSION.dmg"
rm -f "$DMG_PATH"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 160 185 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 460 185 \
  "$DMG_PATH" \
  "$APP_PATH"

echo "==> Signing update with Sparkle"
# The tools unpacked here are executed below with access to the Keychain item
# holding the EdDSA signing key, so what gets extracted is verified before it
# runs rather than trusted because it came from an https URL.
#
# Cached per version: the old guard was "is sign_update present", which meant
# bumping SPARKLE_VERSION silently kept signing with the previous release's
# tools. Checksum for 2.6.4 confirmed against a fresh download from the
# project's GitHub release; update both together when bumping.
SPARKLE_SHA256="50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b"
SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS_DIR/$SPARKLE_VERSION"
if [ ! -x "$SPARKLE_TOOLS_DIR/bin/sign_update" ]; then
  mkdir -p "$SPARKLE_TOOLS_DIR"
  curl -fsSL -o "$SPARKLE_TOOLS_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  echo "$SPARKLE_SHA256  $SPARKLE_TOOLS_DIR/sparkle.tar.xz" | shasum -a 256 -c - || {
    echo "ERROR: Sparkle ${SPARKLE_VERSION} failed checksum verification. Refusing to run its tools." >&2
    rm -f "$SPARKLE_TOOLS_DIR/sparkle.tar.xz"
    exit 1
  }
  tar -xf "$SPARKLE_TOOLS_DIR/sparkle.tar.xz" -C "$SPARKLE_TOOLS_DIR"
fi
# -p prints only the raw EdDSA signature (no "sparkle:edSignature=... length=..."
# wrapper) - that raw value is exactly what admin.dangkhoabach.vn's "Sparkle
# signature" upload field expects. No --account flag: this app's key was
# generated under the Keychain's default "ed25519" account (see docs/release.md).
"$SPARKLE_TOOLS_DIR/bin/sign_update" -p "$DMG_PATH" | tee "$DMG_PATH.sig"
[ -s "$DMG_PATH.sig" ] || { echo "Error: sign_update produced an empty signature." >&2; exit 1; }

# The upload is two separate form fields, so the DMG and the signature can be
# mismatched by hand — pairing a new installer with the previous release's
# signature makes every client reject the update with an error that points
# nowhere near the real cause. Printing the installer's own checksum gives
# something to compare against after uploading.
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | cut -d" " -f1)

echo ""
echo "==> Done. Upload these two files at https://admin.dangkhoabach.vn (app: dkb-monitor):"
echo "    Installer:         $DMG_PATH"
echo "    Sparkle signature:  $DMG_PATH.sig"
echo "    Installer SHA-256: $DMG_SHA256"
echo ""
echo "Reminder: this build is ad-hoc signed, not notarized (no paid Apple"
echo "Developer Program membership) - first launch needs right-click > Open"
echo "to bypass Gatekeeper, same as the old Tauri build."
