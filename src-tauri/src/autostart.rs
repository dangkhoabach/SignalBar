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
#[tauri::command]
pub fn enable_autostart() -> Result<bool, String> {
    let service = app_service();
    match service.register() {
        Ok(()) | Err(ServiceManagementError::AlreadyRegistered) => {}
        Err(e) => return Err(e.to_string()),
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
