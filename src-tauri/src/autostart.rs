#[cfg(target_os = "macos")]
mod platform {
    use smappservice_rs::{AppService, ServiceManagementError, ServiceStatus, ServiceType};

    /// Registers the running app bundle itself (not a helper/plist) as a login
    /// item via macOS's modern ServiceManagement framework. Unlike a LaunchAgent
    /// pointing at the loose executable inside Contents/MacOS, this ties the
    /// registration to the app bundle, so it shows up in System Settings > Login
    /// Items with the correct name/icon and is eligible for the "Allow in the
    /// Background" category.
    fn app_service() -> AppService {
        AppService::new(ServiceType::MainApp)
    }

    #[tauri::command]
    pub fn is_autostart_enabled() -> bool {
        matches!(
            app_service().status(),
            ServiceStatus::Enabled | ServiceStatus::RequiresApproval
        )
    }

    /// Returns `true` if macOS requires the user to approve the item in System
    /// Settings before it will actually run (common on first registration).
    ///
    /// Only calls `register()` when the service isn't already Enabled/
    /// RequiresApproval. `smappservice_rs::ServiceStatus::NotRegistered`'s own
    /// doc comment warns this status is *also* returned "if the service
    /// attempted to reregister after it was already registered" — i.e.
    /// calling register() again on an already-registered service isn't
    /// guaranteed to be the safe no-op `AlreadyRegistered` implies; in
    /// practice this produced a duplicate entry in System Settings > Login
    /// Items. Checking status first avoids ever calling register() a second
    /// time for a service that's already registered.
    #[tauri::command]
    pub fn enable_autostart() -> Result<bool, String> {
        let service = app_service();
        let current_status = service.status();
        if !matches!(current_status, ServiceStatus::Enabled | ServiceStatus::RequiresApproval) {
            match service.register() {
                Ok(()) | Err(ServiceManagementError::AlreadyRegistered) => {}
                Err(e) => return Err(e.to_string()),
            }
        }
        let needs_approval = matches!(service.status(), ServiceStatus::RequiresApproval);
        if needs_approval {
            AppService::open_system_settings_login_items();
        }
        Ok(needs_approval)
    }

    #[tauri::command]
    pub fn disable_autostart() -> Result<(), String> {
        match app_service().unregister() {
            Ok(()) | Err(ServiceManagementError::JobNotFound) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}

/// Windows has no Login Items approval step like macOS — writing the registry
/// value is immediately effective, so `enable_autostart` always reports
/// `needs_approval: false`. Uses `HKCU\...\Run` (per-user, no admin rights
/// required) rather than the machine-wide `HKLM` key or a Startup-folder
/// shortcut, matching how most consumer apps register themselves.
#[cfg(target_os = "windows")]
mod platform {
    use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_WRITE};
    use winreg::RegKey;

    const RUN_KEY_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const VALUE_NAME: &str = "DKB Monitor";

    fn run_key(access: u32) -> std::io::Result<RegKey> {
        RegKey::predef(HKEY_CURRENT_USER).open_subkey_with_flags(RUN_KEY_PATH, access)
    }

    #[tauri::command]
    pub fn is_autostart_enabled() -> bool {
        run_key(KEY_READ)
            .and_then(|key| key.get_value::<String, _>(VALUE_NAME))
            .is_ok()
    }

    #[tauri::command]
    pub fn enable_autostart() -> Result<bool, String> {
        let exe_path = std::env::current_exe().map_err(|e| e.to_string())?;
        // Quoted so the launcher handles paths containing spaces correctly
        // (e.g. "C:\Users\...\DKB Monitor.exe").
        let command = format!("\"{}\"", exe_path.display());
        let key = run_key(KEY_READ | KEY_WRITE).map_err(|e| e.to_string())?;
        key.set_value(VALUE_NAME, &command).map_err(|e| e.to_string())?;
        Ok(false)
    }

    #[tauri::command]
    pub fn disable_autostart() -> Result<(), String> {
        let key = run_key(KEY_READ | KEY_WRITE).map_err(|e| e.to_string())?;
        match key.delete_value(VALUE_NAME) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
mod platform {
    #[tauri::command]
    pub fn is_autostart_enabled() -> bool {
        false
    }

    #[tauri::command]
    pub fn enable_autostart() -> Result<bool, String> {
        Err("Launch at login isn't supported on this platform".into())
    }

    #[tauri::command]
    pub fn disable_autostart() -> Result<(), String> {
        Ok(())
    }
}

// A wildcard re-export, not a named one: #[tauri::command] expands each
// function into hidden sibling marker items (`__cmd__*` etc.) that
// `tauri::generate_handler!` looks up by path — re-exporting only the named
// functions leaves those markers behind and breaks the macro at the call site.
pub use platform::*;
