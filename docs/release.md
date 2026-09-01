# Releasing DKB Monitor (native, macOS)

Everything runs locally on this Mac — no CI, no GitHub Actions secrets.
Same manual-publish model the old Tauri app used (build + sign locally,
then upload by hand to admin.dangkhoabach.vn): only the build tooling
changed (`xcodebuild`/`codesign`/Sparkle instead of `cargo tauri build`/
`tauri-plugin-updater`'s minisign).

## One-time setup

1. **Developer ID signing identity** — must already be in this Mac's login
   Keychain (`security find-identity -v -p codesigning` should list
   "Developer ID Application: ..."). This was already required for the old
   Tauri build too.
2. **Notarization credentials** — store once as a Keychain profile:
   ```bash
   xcrun notarytool store-credentials dkb-release-notarize \
     --apple-id <your-apple-id-email> \
     --team-id <APPLE_TEAM_ID> \
     --password <app-specific-password>
   ```
   Generate the app-specific password at appleid.apple.com if you don't
   already have one saved. `scripts/release.sh` reads the profile name from
   `$NOTARY_PROFILE`, defaulting to `dkb-release-notarize`.
3. **Sparkle EdDSA keypair** — already generated (2026-08-30) under the
   Keychain's default `ed25519` account; `SUPublicEDKey` in `project.yml` is
   already the real public key. Nothing to do here unless that key is ever
   rotated.
4. **`APPLE_TEAM_ID`** — export it in your shell profile (`~/.zshrc` etc.):
   ```bash
   export APPLE_TEAM_ID=XXXXXXXXXX
   ```

## Cutting a release

```bash
./scripts/release.sh
```

Prompts for the version (Enter keeps the current one), bumps the build
number, then runs: `swift test` → `xcodegen generate` → archive → Developer
ID sign → notarize + staple → DMG → Sparkle-sign. Output lands in
`release-output/<version>/` (gitignored): the `.dmg` and its `.sig`
(the raw EdDSA signature, ready to paste as-is).

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
