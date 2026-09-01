# DKB Monitor

A personal, native macOS menu-bar app for monitoring the uptime, SSL certificate expiry, and domain expiry of websites and APIs, plus live system stats — built to run continuously in the background at near-zero idle cost.

## Features

- **HTTP health checks** — status code, response time, and optional response-body assertions on a configurable interval per target.
- **SSL certificate expiry** — checked via the system trust store, with alerts as expiry approaches.
- **Domain (WHOIS/RDAP) expiry** — resolved via RDAP-over-HTTPS where the TLD supports it, falling back to `whois` otherwise. Some ccTLDs (e.g. `.vn`) don't expose this publicly through any method.
- **Live system stats** — CPU, memory, swap, temperature (SMC), battery, and network, refreshed continuously and surfaced both in a System tab and the menu bar dropdown, with alerts for high temperature/low battery.
- **Running Apps** — a Task-Manager-style list of user-facing apps with CPU/memory usage and status, sortable, with Quit/Force Quit.
- **Groups** — targets group by root domain (subdomains fold under it), with drag-and-drop reordering of both targets and groups, and inline group renaming.
- **Pause/resume checks** — snooze a target for 30m/1h/4h/24h or indefinitely.
- **Native macOS integration** — `MenuBarExtra` with live CPU/RAM/uptime summary, native notifications (click-to-navigate), launch-at-login, light/dark theme, in-app language switching (English/Vietnamese).
- **Scheduled email reports** — a weekly/monthly summary of uptime and incidents sent over SMTP, with the app password stored in the macOS Keychain (never in the database or config).
- **Import/export/clear** domains as JSON.

## Tech stack

- **Swift 6 + SwiftUI**, targeting macOS 14+.
- **`DKBMonitorCore`** — a headless Swift package (Foundation + GRDB only, no AppKit) holding the domain logic: target CRUD, the HTTP/SSL/domain check scheduler, alert/report generation, and SQLite storage via [GRDB](https://github.com/groue/GRDB.swift).
- **`DKBMonitorApp`** — the app target: SwiftUI views, `MenuBarExtra`, AppKit-only system integration (SMC temperature/fan reads via IOKit, process list via `libproc`, login item, notifications), and [Sparkle](https://sparkle-project.org/) for auto-updates.
- **`xcodegen`** generates the `.xcodeproj` from `project.yml` — the project file itself isn't committed.

## Project structure

```
project.yml                          xcodegen spec (targets, deps, Info.plist, Sparkle keys)
DKBMonitorApp/
  App/                                App/Scene setup, window management, Sparkle updater, login item
  UI/                                 SwiftUI views + view models (Overview, System, Settings, Target detail)
  System/                             SMC reader, process list (libproc), system stats service
  Notifications/                      UNUserNotificationCenter wrapper, click-to-navigate routing
DKBMonitorCore/
  Sources/DKBMonitorCore/
    Domain/                           Scheduler, HttpChecker, ExpiryChecker, EmailReportSender, ReportGenerator
    Data/                             AppDatabase (GRDB), TargetRepository, SettingsRepository
    Models/                           Target, TargetOverview, Incident, CheckResult, ExpiryStatus
    System/                           Cross-platform-safe stats/process value types
  Tests/                              swift-testing suite for DKBMonitorCore
docs/
  swift-native-port-plan.md           full history of the Tauri → native port
  release.md                          local build/sign/notarize/publish process
scripts/
  release.sh                          builds, signs, notarizes, DMGs, and Sparkle-signs a release
```

## Getting started

```bash
brew install xcodegen
xcodegen generate
open DKBMonitorNative.xcodeproj
```

Run the `DKBMonitorApp` scheme from Xcode (choose your signing team under Signing & Capabilities first). `DKBMonitorCore` can also be tested headlessly:

```bash
cd DKBMonitorCore
swift test
```

## Releasing (Check for Updates)

Sparkle reads `SUFeedURL`/`SUPublicEDKey` from `project.yml`'s `Info.plist` properties. `SUFeedURL` points at `updates.dangkhoabach.vn` (the same domain the old Tauri app's updater used) — not GitHub Releases, which this project doesn't publish to.

Releases are built, ad-hoc signed, and uploaded entirely from this machine — no CI, no paid Apple Developer Program membership (so no notarization; first launch needs right-click → Open, same as the old Tauri build). Run `./scripts/release.sh`, then upload the resulting DMG + `.sig` via admin.dangkhoabach.vn's web UI. See `docs/release.md` for details.
