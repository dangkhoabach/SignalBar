# Releasing DKB Monitor (native, macOS)

Everything runs locally on this Mac — no CI, no GitHub Actions secrets.
Same manual-publish model the old Tauri app used (build + sign locally,
then upload by hand to admin.dangkhoabach.vn): only the build tooling
changed (`xcodebuild`/`codesign`/Sparkle instead of `cargo tauri build`/
`tauri-plugin-updater`'s minisign).

No Apple Developer Program membership (the $99/year one) exists for this
project, same as the old Tauri build — so there's no Developer ID signing
and no notarization here. Builds are **ad-hoc signed** instead (free,
built into Xcode/`codesign`), which means end users have to right-click →
Open on first launch to get past Gatekeeper's "unidentified developer"
warning — the same experience the Tauri build already had. If a paid
membership is ever added later, `scripts/release.sh` would need a real
Developer ID identity + `xcrun notarytool` step added back in.

## One-time setup

1. **Sparkle EdDSA keypair** — already generated (2026-08-30) under the
   Keychain's default `ed25519` account; `SUPublicEDKey` in `project.yml` is
   already the real public key. Nothing to do here unless that key is ever
   rotated.
2. **`create-dmg`** — styles the installer DMG's Finder window (icon layout,
   Applications drop link) instead of a bare `hdiutil` copy:
   ```bash
   brew install create-dmg
   ```
   No custom background image — a dark particle-network image was tried
   (`scripts/generate-dmg-background.py`) but Finder always draws icon name
   labels in black with no way to override that, so "DKB Monitor"/
   "Applications" were essentially unreadable against it. Back to Finder's
   plain default background, where the labels are legible.

## Cutting a release

```bash
./scripts/release.sh
```

Prompts for the version (e.g. `2.0.1`; Enter keeps the current one), writes
that exact string into both `CFBundleShortVersionString` and
`CFBundleVersion` in `project.yml` (the actual source of truth — see the
comment above `CFBundleShortVersionString` there; editing `Info.plist`
directly gets silently discarded by the next `xcodegen generate`), then
runs: `swift test` → `xcodegen generate` → ad-hoc-signed Release build →
DMG → Sparkle-sign. Output lands in `release-output/<version>/`
(gitignored): the `.dmg` and its `.sig` (the raw EdDSA signature, ready to
paste as-is).

Both version fields are always set identically — an earlier version of
this script split the input into a 2-component marketing version plus a
separate build number (`2.0.1` → version `2.0`, build `1`), which meant a
second release sharing the same `MAJOR.MINOR` reused the exact same
`CFBundleVersion` as the first, so Sparkle could never tell the two apart
and kept reporting an update as available even once the user was already
on the latest DMG.

## Uploading a release

Not automated — go to **admin.dangkhoabach.vn → Apps → dkb-monitor →
Republish**, tick macOS, and upload:

| Form field | File |
|---|---|
| Installer file | `DKB-Monitor-<version>.dmg` |
| Sparkle signature (.sig) | `DKB-Monitor-<version>.dmg.sig` (paste its contents) |

Leave "Updater bundle"/"Signature (.sig)" (the Tauri-format fields) empty —
those are for the retired Tauri build only. The admin panel writes
`updates.dangkhoabach.vn/dkb-monitor/appcast.xml` from the Sparkle fields,
which `SUFeedURL` in `project.yml` points at.

Once the first version has been uploaded this way, flip
`SUEnableAutomaticChecks` to `true` in `project.yml` (it's `false` until
then, otherwise Sparkle pops an "Unable to Check for Updates" alert on every
launch since there's no feed to reach yet) and re-run `xcodegen generate`.
