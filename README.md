# DKB Monitor

A personal, macOS-first menu-bar app for monitoring the uptime, SSL certificate expiry, and domain expiry of websites and APIs. Built with **Tauri 2 + React + SQLite** for low idle resource usage, since it's designed to run continuously in the background.

## Features

- **HTTP health checks** — status code, response time, and optional response-body assertions on a configurable interval per target.
- **SSL certificate expiry** — checked via the system `openssl`, with native alerts as expiry approaches.
- **Domain (WHOIS/RDAP) expiry** — resolved via RDAP-over-HTTPS where the TLD supports it, falling back to `whois` otherwise. Some ccTLDs (e.g. `.vn`) don't expose this publicly through any method.
- **Live system stats** — CPU (total + per-core), memory, swap, disk, GPU, and network status (connection type, Wi-Fi SSID, local IP), refreshed continuously and also surfaced in the menu bar dropdown.
- **Groups** — targets auto-group by root domain (subdomains fold under it), with drag-and-drop reordering of both targets and groups, and inline group renaming.
- **Native macOS integration** — menu bar tray with live CPU/RAM/uptime summary, native notifications, launch-at-login, vibrancy-matched light/dark theme.
- **Scheduled email reports** — a daily/weekly/monthly summary of uptime and incidents sent over SMTP, with the app password stored in the macOS Keychain (never in the database or config).
- **Bilingual UI** — English and Vietnamese.

## Tech stack

- **Frontend**: React 19 + TypeScript + Vite, Tailwind v4, shadcn/ui on [Base UI](https://base-ui.com/) primitives, `react-router`, `recharts` for latency charts, `sonner` for toasts.
- **Backend**: Rust + Tauri 2, `rusqlite` (bundled SQLite) for storage, `reqwest` for HTTP checks and RDAP lookups, `lettre` for SMTP, `sysinfo` for system stats, `keyring` for credential storage.

## Project structure

```
src/                        React frontend
  components/                shared UI (shadcn components, layout, dialogs)
  pages/                      Domains, System, Settings, Email report setup, Target detail
  lib/                        API bindings, i18n, utils
src-tauri/src/
  commands.rs                 Tauri commands (target CRUD, overview, uptime summary, group rename...)
  scheduler.rs                 background tick loop: HTTP/SSL/domain checks, alerts, scheduled reports
  expiry_check.rs               SSL/domain expiry + RDAP/whois logic
  sysstats.rs                   CPU/RAM/disk/GPU/network stats
  mail.rs                       SMTP sending + report generation
  settings.rs                   app settings persistence + Keychain access
  db.rs                         SQLite schema/migrations
  tray_icon.rs                  menu bar glyph rendering
```

## Getting started

```bash
npm install
npm run tauri dev     # run in development
npm run tauri build   # produce a release .app / .dmg
```

Requires Rust (via `rustup`) and Xcode Command Line Tools on macOS.

## Versioning

Each release build bumps the patch version (`src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml`, `package.json`) — e.g. `0.1.3` → `0.1.4`. Minor/major bumps are manual.

## Publishing an update (Check for Updates)

The app checks `https://updates.dangkhoabach.vn/dkb-monitor/latest.json` (Tauri updater plugin, configured in `tauri.conf.json`). To ship a new version:

```bash
set -a; source .env.release; set +a   # loads the local signing key + password (gitignored)
npm run tauri build
```

This produces, in addition to the normal `.dmg`:
- `src-tauri/target/release/bundle/macos/DKB Monitor.app.tar.gz`
- `src-tauri/target/release/bundle/macos/DKB Monitor.app.tar.gz.sig`

Write `latest.json` (version, notes, `pub_date`, and a `darwin-aarch64` platform entry with the `.sig` file's contents as `signature` and a URL pointing at the artifact once uploaded), then copy `latest.json` + the two files above into `~/MyWebsite/deploy/updates/dkb-monitor/` and run `~/MyWebsite/deploy/publish-update.sh dkb-monitor` to upload them.

The signing keypair lives at `~/.tauri/dkb-monitor-updater.key` (private, never committed) with its public half embedded in `tauri.conf.json`. Losing the private key means old installs can never verify a new signed update again — back it up somewhere safe.
