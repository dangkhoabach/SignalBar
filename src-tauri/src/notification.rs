//! Native notifications with click-through support.
//!
//! tauri-plugin-notification's own `.show()` is fire-and-forget: it discards
//! the handle notify-rust returns, so there is no way to know a notification
//! was clicked. This module calls notify-rust directly instead, so it can
//! wait for a response and react to it (bring the window forward, tell the
//! frontend which route to open).

use tauri::{AppHandle, Emitter};

/// Shows a native notification and, on a background OS thread, waits for the
/// user to interact with it. On click, un-hides/focuses the main window and,
/// if `route` is set, asks the frontend to navigate there via the
/// `notification-clicked` event.
///
/// Does not check the user's "Notifications" setting — callers that should
/// respect it (scheduler alerts) must check before calling this.
pub fn show(app: &AppHandle, title: &str, body: &str, route: Option<String>) {
    let title = title.to_string();
    let body = body.to_string();
    let app = app.clone();

    // notify-rust's wait for a click blocks the calling thread until the user
    // interacts or the notification is dismissed/expires — must not run on a
    // tokio worker (would stall the scheduler) or the main thread (would
    // freeze the UI), so each notification gets its own plain OS thread.
    std::thread::spawn(move || {
        let mut notification = notify_rust::Notification::new();
        notification.summary(&title).body(&body).auto_icon();

        // Mirrors tauri-plugin-notification's own desktop::show() setup
        // (see tauri-plugin-notification-2.3.3/src/desktop.rs), which we
        // bypass here to get a click callback:
        #[cfg(target_os = "macos")]
        {
            // Unsigned dev builds can't register their own bundle id with
            // NSUserNotificationCenter, so fall back to a bundle id that's
            // always present (same placeholder the plugin uses in dev).
            let _ = notify_rust::set_application(if tauri::is_dev() {
                "com.apple.Terminal"
            } else {
                &app.config().identifier
            });
        }
        #[cfg(windows)]
        {
            // Only set the AUMID for the installed app — a raw target/debug
            // or target/release binary has no matching Start Menu shortcut,
            // and setting it anyway would break toast delivery entirely.
            if let Ok(exe) = tauri::utils::platform::current_exe() {
                if let Some(exe_dir) = exe.parent() {
                    let sep = std::path::MAIN_SEPARATOR;
                    let curr_dir = exe_dir.display().to_string();
                    if !(curr_dir.ends_with(&format!("{sep}target{sep}debug"))
                        || curr_dir.ends_with(&format!("{sep}target{sep}release")))
                    {
                        notification.app_id(&app.config().identifier);
                    }
                }
            }
        }

        // macOS's legacy NSUserNotificationCenter backend (the one this app
        // uses — no `preview-macos-un` feature enabled) only blocks waiting
        // for a response, and thus only ever reports a click, when the
        // notification has at least one action button; a plain title+body
        // notification with none never waits (see mac-notification-sys's
        // `needs_response()`). Adding one satisfies that and doubles as a
        // harmless extra affordance on Windows — clicking the body itself
        // still works identically to clicking this button on both platforms.
        notification.action("default", "Xem chi tiết");

        let Ok(handle) = notification.show() else {
            return;
        };

        let _ = handle.wait_for_response(move |response: &notify_rust::NotificationResponse| {
            if matches!(response, notify_rust::NotificationResponse::Closed(_)) {
                return;
            }
            crate::show_main_window(&app);
            if let Some(route) = route {
                let _ = app.emit("notification-clicked", route);
            }
        });
    });
}
