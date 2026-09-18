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

The version must be `MAJOR.MINOR.PATCH` and not lower than the current one
(Sparkle would never offer a lower one). If anything fails after the
version was written, `project.yml` is restored, so a failed run never
leaves a version behind that was never released.

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

`SUEnableAutomaticChecks` is deliberately **absent** from `project.yml` and
must stay that way: with the key unset, Sparkle asks the user on first launch
whether it may check automatically, and the answer is theirs to change under
Settings → Updates. Pinning it to `true` (as an early version of this project
did) skipped that consent prompt and phoned home daily without ever asking;
pinning it to `false` decides "no" on the user's behalf just as silently.
`SUScheduledCheckInterval` (once a day) only applies once they have said yes.
