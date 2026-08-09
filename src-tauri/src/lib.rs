mod autostart;
mod commands;
mod db;
mod expiry_check;
mod mail;
mod models;
mod notification;
mod scheduler;
mod settings;
mod sysstats;
mod tray_icon;

use rusqlite::Connection;
use std::sync::Mutex;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager, WebviewWindowBuilder, WindowEvent};
// `ActivationPolicy` and `traffic_light_position` (further below) don't even
// exist on non-macOS targets — the tauri crate only re-exports/compiles them
// under `#[cfg(target_os = "macos")]`, so this import itself must be gated,
// not just its call sites.
#[cfg(target_os = "macos")]
use tauri::{ActivationPolicy, LogicalPosition};

/// Regular apps (the default) always count as foreground-capable to macOS,
/// even with zero open windows — Login Items then reports them as "Not
/// running in background" regardless of whether they're actually just
/// sitting in the tray. Switching to Accessory (no Dock icon, background-only)
/// while hidden is what makes the OS recognize this as an actual background
/// process; switching back to Regular when the window reopens restores the
/// normal Dock presence. Windows/Linux have no equivalent concept — the tray
/// icon alone is enough for the OS to treat this as a background app, so
/// there's nothing to toggle there.
pub(crate) fn show_main_window(app: &tauri::AppHandle) {
    #[cfg(target_os = "macos")]
    let _ = app.set_activation_policy(ActivationPolicy::Regular);
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

pub struct AppState {
    pub db: Mutex<Connection>,
    pub http_client: reqwest::Client,
}

/// The macOS vibrancy blur is a native layer tied to the window's
/// NSAppearance, independent from our CSS theme class. Without this, picking
/// "light" in-app only recolors text/overlays while the native blur stays on
/// whatever appearance the window started with, making content unreadable.
#[tauri::command]
fn set_native_theme(window: tauri::Window, theme: String) -> Result<(), String> {
    let theme = match theme.as_str() {
        "light" => Some(tauri::Theme::Light),
        "dark" => Some(tauri::Theme::Dark),
        _ => None,
    };
    window.set_theme(theme).map_err(|e| e.to_string())
}

/// Fires regardless of the "Notifications" setting, unlike scheduler.rs's
/// `notify` — this is an explicit user action to verify the OS permission
/// and delivery pipeline work, not a real alert that should be silenced.
#[tauri::command]
fn send_test_notification(app: tauri::AppHandle) -> Result<(), String> {
    notification::show(
        &app,
        "DKB Monitor",
        "Đây là thông báo test. Notification đang hoạt động bình thường.",
        None,
    );
    Ok(())
}

/// tauri-plugin-notification's desktop backend always reports permission as
/// "Granted" regardless of the real OS state (it doesn't wrap the native
/// UNUserNotificationCenter authorization API on macOS), so there's no
/// reliable way to detect denial from Rust. Instead of guessing, this just
/// deep-links straight to this app's own Notifications settings pane so the
/// user can check/grant it themselves — the same pattern System Settings
/// uses for its own "Login Items" deep link.
#[cfg(target_os = "macos")]
#[tauri::command]
fn open_notification_settings(app: tauri::AppHandle) -> Result<(), String> {
    let identifier = &app.config().identifier;
    std::process::Command::new("open")
        .arg(format!(
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id={identifier}"
        ))
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// `ms-settings:notifications` is Windows' equivalent deep link (opens the
/// system Notifications settings page — Windows doesn't expose a per-app
/// pane via URI the way macOS does, so this is the closest match). Launched
/// through `explorer.exe` rather than `cmd /C start`, since `explorer` is the
/// documented way to hand a `ms-settings:` URI to its registered handler
/// without going through a shell that would need its own quoting/escaping.
#[cfg(target_os = "windows")]
#[tauri::command]
fn open_notification_settings(_app: tauri::AppHandle) -> Result<(), String> {
    std::process::Command::new("explorer")
        .arg("ms-settings:notifications")
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
#[tauri::command]
fn open_notification_settings(_app: tauri::AppHandle) -> Result<(), String> {
    Err("Not supported on this platform".into())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            // The "main" window is declared in tauri.conf.json with
            // "create": false so it's built here instead — there's no JSON
            // config option for traffic-light position, only this builder
            // method, and from_config() carries over every other window
            // setting (size, titleBarStyle, transparent, dragDropEnabled...)
            // unchanged so nothing else about it needs to be duplicated.
            let main_window_config = app
                .config()
                .app
                .windows
                .iter()
                .find(|w| w.label == "main")
                .expect("main window must be declared in tauri.conf.json")
                .clone();
            let window_builder = WebviewWindowBuilder::from_config(app, &main_window_config)?;
            // traffic_light_position has no equivalent on Windows/Linux (there
            // are no traffic-light buttons to reposition) — the window just
            // uses its native title bar there instead.
            #[cfg(target_os = "macos")]
            let window_builder = window_builder.traffic_light_position(LogicalPosition::new(18.0, 22.0));
            window_builder.build()?;

            let app_data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&app_data_dir)?;
            let db_path = app_data_dir.join("dkb-monitor.db");
            let conn = db::init_db(&db_path)?;
            let http_client = reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()?;
            app.manage(AppState {
                db: Mutex::new(conn),
                http_client,
            });
            app.manage(sysstats::SysState::new());

            let uptime_item = MenuItem::with_id(app, "uptime-stat", "Domains: —", false, None::<&str>)?;
            let cpu_item = MenuItem::with_id(app, "cpu-stat", "CPU: —", false, None::<&str>)?;
            let ram_item = MenuItem::with_id(app, "ram-stat", "RAM: —", false, None::<&str>)?;
            let temp_item = MenuItem::with_id(app, "temp-stat", "Temperature: —", false, None::<&str>)?;
            let battery_item = MenuItem::with_id(app, "battery-stat", "Battery: —", false, None::<&str>)?;
            let separator = PredefinedMenuItem::separator(app)?;
            let show_item = MenuItem::with_id(app, "show", "Show DKB Monitor", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let tray_menu = Menu::with_items(
                app,
                &[
                    &uptime_item,
                    &cpu_item,
                    &ram_item,
                    &temp_item,
                    &battery_item,
                    &separator,
                    &show_item,
                    &quit_item,
                ],
            )?;

            fn refresh_tray_stats(
                app: &tauri::AppHandle,
                uptime_item: &MenuItem<tauri::Wry>,
                cpu_item: &MenuItem<tauri::Wry>,
                ram_item: &MenuItem<tauri::Wry>,
                temp_item: &MenuItem<tauri::Wry>,
                battery_item: &MenuItem<tauri::Wry>,
            ) {
                let sys_state = app.state::<sysstats::SysState>();
                let stats = {
                    let mut inner = sys_state.inner.lock().unwrap();
                    sysstats::snapshot(&mut inner)
                };
                let _ = cpu_item.set_text(format!("CPU: {:.0}%", stats.cpu_percent));
                let _ = ram_item.set_text(format!(
                    "RAM: {:.1} / {:.1} GB",
                    stats.ram_used_mb as f64 / 1024.0,
                    stats.ram_total_mb as f64 / 1024.0
                ));
                let _ = temp_item.set_text(match stats.cpu_temp_celsius {
                    Some(temp) => format!("Temperature: {temp:.0}°C"),
                    None => "Temperature: N/A".to_string(),
                });
                let _ = battery_item.set_text(match stats.battery_percent {
                    Some(percent) if stats.battery_charging.unwrap_or(false) => {
                        format!("Battery: {percent:.0}% (Charging)")
                    }
                    Some(percent) => format!("Battery: {percent:.0}%"),
                    None => "Battery: N/A".to_string(),
                });

                let app_state = app.state::<AppState>();
                let summary = app_state.db.lock().ok().and_then(|conn| commands::uptime_summary(&conn).ok());
                if let Some((up, total)) = summary {
                    let _ = uptime_item.set_text(format!("Domains: {up}/{total} up"));
                }
            }

            refresh_tray_stats(app.handle(), &uptime_item, &cpu_item, &ram_item, &temp_item, &battery_item);

            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut interval = tokio::time::interval(Duration::from_secs(3));
                // Same reasoning as scheduler.rs's tick interval: without this, a long
                // sleep/background stretch makes this burst through every missed tick
                // on wake, each one spawning several subprocesses (route, networksetup,
                // pmset, ioreg...) — a real source of the "reopen after a while = lag"
                // symptom.
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                loop {
                    interval.tick().await;
                    refresh_tray_stats(&app_handle, &uptime_item, &cpu_item, &ram_item, &temp_item, &battery_item);
                }
            });

            TrayIconBuilder::with_id("main-tray")
                .menu(&tray_menu)
                .icon(tray_icon::pulse_glyph())
                .icon_as_template(true)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_main_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

            // Start from Tauri's own platform-default menu (File/Edit/View/Window
            // as already shown) and only extend the Help submenu, so nothing
            // else about the native menu bar regresses.
            let app_menu = Menu::default(app.handle())?;
            for item in app_menu.items()? {
                if let Some(submenu) = item.as_submenu() {
                    if submenu.text()? == "Help" {
                        // A plain menu item rather than PredefinedMenuItem::about: the
                        // native macOS About panel only accepts a flat NSString for
                        // "Credits" (muda wraps it in NSAttributedString::from_nsstring
                        // with no rich-text/link parsing), so there's no way to make
                        // the developer credit clickable from that panel. An in-app
                        // dialog gets a real clickable link instead.
                        let about = MenuItem::with_id(app, "about", "About DKB Monitor", true, None::<&str>)?;
                        let check_update = MenuItem::with_id(
                            app,
                            "check-update",
                            "Check for Updates…",
                            true,
                            None::<&str>,
                        )?;
                        submenu.append(&about)?;
                        submenu.append(&PredefinedMenuItem::separator(app)?)?;
                        submenu.append(&check_update)?;
                    }
                }
            }
            app.set_menu(app_menu)?;

            let update_app_handle = app.handle().clone();
            app.on_menu_event(move |app, event| {
                match event.id().as_ref() {
                    "check-update" => {
                        // The updater plugin's check/download/install flow runs
                        // entirely from the frontend (it needs a UI for progress
                        // and the restart prompt); this just brings the window
                        // forward and tells it to start.
                        show_main_window(app);
                        let _ = update_app_handle.emit("check-update-clicked", ());
                    }
                    "about" => {
                        show_main_window(app);
                        let _ = update_app_handle.emit("show-about-clicked", ());
                    }
                    _ => {}
                }
            });

            scheduler::spawn(app.handle().clone());

            #[cfg(target_os = "macos")]
            {
                let window = app.get_webview_window("main").unwrap();
                window_vibrancy::apply_vibrancy(
                    &window,
                    window_vibrancy::NSVisualEffectMaterial::Sidebar,
                    None,
                    None,
                )
                .expect("failed to apply macOS vibrancy");
            }

            // Mica only exists on Windows 11 (window-vibrancy returns an Err
            // on Windows 10, which apply_vibrancy above `.expect()`s on for
            // macOS since it's expected to always succeed there — Mica isn't,
            // so this is allowed to silently no-op instead of crashing the
            // app over a purely cosmetic effect).
            #[cfg(target_os = "windows")]
            {
                let window = app.get_webview_window("main").unwrap();
                let _ = window_vibrancy::apply_mica(&window, None);
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            // Keep running in the tray instead of quitting when the window is closed,
            // since this app is meant to keep monitoring in the background.
            if let WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                #[cfg(target_os = "macos")]
                let _ = window.app_handle().set_activation_policy(ActivationPolicy::Accessory);
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::list_targets,
            commands::add_target,
            commands::update_target,
            commands::delete_target,
            commands::delete_targets,
            commands::set_targets_enabled,
            commands::pause_target,
            commands::resume_target,
            commands::check_target_now,
            commands::check_all_now,
            commands::get_history,
            commands::get_history_for_date,
            commands::get_overview,
            commands::get_target_detail,
            commands::reorder_targets,
            commands::get_uptime_summary,
            commands::rename_group,
            commands::export_domains,
            commands::import_domains,
            commands::clear_all_targets,
            settings::get_settings,
            settings::update_settings,
            settings::send_test_email,
            settings::get_group_order,
            settings::set_group_order,
            set_native_theme,
            send_test_notification,
            open_notification_settings,
            sysstats::get_system_stats,
            autostart::is_autostart_enabled,
            autostart::enable_autostart,
            autostart::disable_autostart,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_app_handle, _event| {
            // macOS sends this when the user reopens the app (Dock/Launchpad/
            // Finder) while it's already running — e.g. right after closing
            // the window, which only hides it and switches to Accessory mode
            // rather than quitting (see the CloseRequested handler above).
            // Without this, that second "open" click does nothing visible:
            // the process is already running, so macOS never launches a new
            // window, and nothing else here was listening for the reopen.
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen { .. } = _event {
                show_main_window(_app_handle);
            }
        });
}
