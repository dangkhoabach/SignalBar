mod commands;
mod db;
mod expiry_check;
mod mail;
mod models;
mod scheduler;
mod settings;
mod tray_icon;

use rusqlite::Connection;
use std::sync::Mutex;
use std::time::Duration;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Manager, WindowEvent};

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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .setup(|app| {
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

            let show_item = MenuItem::with_id(app, "show", "Show DKB Monitor", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let tray_menu = Menu::with_items(app, &[&show_item, &quit_item])?;

            TrayIconBuilder::with_id("main-tray")
                .menu(&tray_menu)
                .icon(tray_icon::pulse_glyph())
                .icon_as_template(true)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .build(app)?;

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

            Ok(())
        })
        .on_window_event(|window, event| {
            // Keep running in the tray instead of quitting when the window is closed,
            // since this app is meant to keep monitoring in the background.
            if let WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::list_targets,
            commands::add_target,
            commands::update_target,
            commands::delete_target,
            commands::get_history,
            commands::get_overview,
            commands::get_target_detail,
            commands::reorder_targets,
            settings::get_settings,
            settings::update_settings,
            settings::save_smtp_password,
            settings::clear_smtp_password,
            settings::send_test_email,
            settings::get_group_order,
            settings::set_group_order,
            set_native_theme,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
