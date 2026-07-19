use serde::Serialize;
use std::sync::{Mutex, OnceLock};
use sysinfo::{Disks, System};

pub struct SysState {
    pub sys: Mutex<System>,
}

impl SysState {
    pub fn new() -> Self {
        Self {
            sys: Mutex::new(System::new_all()),
        }
    }
}

#[derive(Serialize, Clone)]
pub struct SystemStats {
    pub cpu_percent: f32,
    pub cpu_cores: Vec<f32>,
    pub ram_used_mb: u64,
    pub ram_total_mb: u64,
    pub swap_used_mb: u64,
    pub swap_total_mb: u64,
    pub disk_used_gb: f64,
    pub disk_total_gb: f64,
    pub gpu_name: Option<String>,
    pub gpu_percent: Option<f32>,
    pub network_connected: bool,
    /// Hardware port name, e.g. "Wi-Fi" or "Ethernet".
    pub network_type: Option<String>,
    /// Wi-Fi SSID; always `None` for wired connections.
    pub network_name: Option<String>,
    /// LAN-side IPv4 address of the active interface (never the public IP).
    pub network_local_ip: Option<String>,
}

#[derive(Default)]
struct NetworkStatus {
    connected: bool,
    interface_type: Option<String>,
    name: Option<String>,
    local_ip: Option<String>,
}

/// Root-volume space, in GB (used, total). Picks the disk mounted at "/" if
/// present, otherwise falls back to the first disk sysinfo reports.
fn disk_usage_gb() -> (f64, f64) {
    let disks = Disks::new_with_refreshed_list();
    let disk = disks
        .list()
        .iter()
        .find(|d| d.mount_point().to_str() == Some("/"))
        .or_else(|| disks.list().first());

    match disk {
        Some(d) => {
            let total = d.total_space() as f64 / 1_073_741_824.0;
            let available = d.available_space() as f64 / 1_073_741_824.0;
            (total - available, total)
        }
        None => (0.0, 0.0),
    }
}

/// The GPU model name rarely changes at runtime, and `system_profiler` takes
/// a few hundred ms to run, so it's queried once and cached instead of on
/// every poll.
#[cfg(target_os = "macos")]
fn gpu_name() -> Option<String> {
    static NAME: OnceLock<Option<String>> = OnceLock::new();
    NAME.get_or_init(|| {
        let output = std::process::Command::new("system_profiler")
            .args(["SPDisplaysDataType"])
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        text.lines()
            .find(|l| l.trim_start().starts_with("Chipset Model:"))
            .map(|l| l.split(':').nth(1).unwrap_or("").trim().to_string())
    })
    .clone()
}

/// Apple's public APIs don't expose live GPU utilization; `ioreg` dumping the
/// IOAccelerator's performance-statistics dictionary (the same technique used
/// by menu-bar utilities like Stats/iStat Menus) is the only practical source.
#[cfg(target_os = "macos")]
fn gpu_percent() -> Option<f32> {
    let output = std::process::Command::new("ioreg")
        .args(["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let key = "\"Device Utilization %\"=";
    let idx = text.find(key)?;
    let rest = &text[idx + key.len()..];
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse::<f32>().ok()
}

/// No public Windows API gives a one-line adapter name as cheaply as WMI/CIM;
/// `Get-CimInstance` takes ~100-200ms so — same reasoning as macOS's
/// `system_profiler` above — this is cached for the process lifetime instead
/// of queried on every poll.
#[cfg(target_os = "windows")]
fn gpu_name() -> Option<String> {
    static NAME: OnceLock<Option<String>> = OnceLock::new();
    NAME.get_or_init(|| {
        let output = std::process::Command::new("powershell")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "(Get-CimInstance Win32_VideoController | Select-Object -First 1 -ExpandProperty Name)",
            ])
            .output()
            .ok()?;
        let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if name.is_empty() {
            None
        } else {
            Some(name)
        }
    })
    .clone()
}

/// Unlike macOS's `ioreg` trick, live GPU utilization on Windows only comes
/// from perf counters that report per-"engine" instances with unstable,
/// driver-specific names (`Get-Counter '\GPU Engine(*)\Utilization
/// Percentage'`) — summing them reliably needs per-vendor handling that isn't
/// worth the fragility here, so this is left unavailable rather than guessed.
#[cfg(target_os = "windows")]
fn gpu_percent() -> Option<f32> {
    None
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn gpu_name() -> Option<String> {
    None
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn gpu_percent() -> Option<f32> {
    None
}

/// The device backing the current default route (e.g. "en0"). `route`
/// exits non-zero when there's no default route at all (offline), which is
/// itself useful signal, but the interface line is only present on stdout
/// when a route does exist — so a parse failure here already means "no
/// connection" regardless of the exit code.
#[cfg(target_os = "macos")]
fn active_interface() -> Option<String> {
    let output = std::process::Command::new("route")
        .args(["-n", "get", "default"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines().find_map(|l| {
        l.trim()
            .strip_prefix("interface: ")
            .map(|s| s.trim().to_string())
    })
}

/// Maps a device name to its human-readable hardware port (e.g. "en0" ->
/// "Wi-Fi" or "Ethernet"), the same names shown in System Settings > Network.
#[cfg(target_os = "macos")]
fn hardware_port_for(device: &str) -> Option<String> {
    let output = std::process::Command::new("networksetup")
        .arg("-listallhardwareports")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let mut current_port: Option<&str> = None;
    for line in text.lines() {
        if let Some(port) = line.strip_prefix("Hardware Port: ") {
            current_port = Some(port.trim());
        } else if let Some(dev) = line.strip_prefix("Device: ") {
            if dev.trim() == device {
                return current_port.map(|p| p.to_string());
            }
        }
    }
    None
}

#[cfg(target_os = "macos")]
fn wifi_ssid(device: &str) -> Option<String> {
    let output = std::process::Command::new("networksetup")
        .args(["-getairportnetwork", device])
        .output()
        .ok()?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .strip_prefix("Current Wi-Fi Network: ")
        .map(|s| s.to_string())
}

/// The interface's LAN-side IPv4 address (`ifconfig`'s "inet" line) — never
/// the public/WAN IP, which would require an external network request.
#[cfg(target_os = "macos")]
fn local_ip_for(device: &str) -> Option<String> {
    let output = std::process::Command::new("ifconfig").arg(device).output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines().find_map(|l| {
        let l = l.trim();
        l.strip_prefix("inet ")
            .and_then(|rest| rest.split_whitespace().next())
            .map(|ip| ip.to_string())
    })
}

#[cfg(target_os = "macos")]
fn network_status() -> NetworkStatus {
    let Some(device) = active_interface() else {
        return NetworkStatus::default();
    };
    let interface_type = hardware_port_for(&device);
    let is_wifi = interface_type.as_deref().is_some_and(|p| p.contains("Wi-Fi"));
    let name = if is_wifi { wifi_ssid(&device) } else { None };
    let local_ip = local_ip_for(&device);
    NetworkStatus {
        connected: true,
        interface_type,
        name,
        local_ip,
    }
}

/// One PowerShell invocation gathering interface/type/SSID/IP together,
/// rather than four separate spawns like the macOS path above — PowerShell's
/// ~100-300ms startup cost is high enough that doing it 4x per poll (this
/// runs every few seconds) would be a real, avoidable cost on Windows.
/// `netsh wlan show interfaces` is still shelled out to for the SSID line
/// specifically — `Get-NetConnectionProfile`/`Get-NetAdapter` don't expose it,
/// and `netsh` is a stable, always-present Windows component (unlike a
/// third-party tool).
#[cfg(target_os = "windows")]
const NETWORK_STATUS_SCRIPT: &str = r#"
$ErrorActionPreference = 'SilentlyContinue'
$profile = Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -eq 'Internet' -or $_.IPv6Connectivity -eq 'Internet' } | Select-Object -First 1
if (-not $profile) { Write-Output 'DISCONNECTED'; exit }
$alias = $profile.InterfaceAlias
$adapter = Get-NetAdapter -Name $alias
$isWifi = $adapter.PhysicalMediaType -like '*802.11*'
$type = if ($isWifi) { 'Wi-Fi' } else { 'Ethernet' }
$ssid = ''
if ($isWifi) {
    $wlanOutput = netsh wlan show interfaces
    $ssidLine = $wlanOutput | Select-String '^\s*SSID\s*:\s*(.+)$' | Select-Object -First 1
    if ($ssidLine) { $ssid = $ssidLine.Matches[0].Groups[1].Value.Trim() }
}
$ip = (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
Write-Output "CONNECTED|$type|$ssid|$ip"
"#;

#[cfg(target_os = "windows")]
fn network_status() -> NetworkStatus {
    let Ok(output) = std::process::Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", NETWORK_STATUS_SCRIPT])
        .output()
    else {
        return NetworkStatus::default();
    };
    let text = String::from_utf8_lossy(&output.stdout);
    let line = text.trim();
    if !line.starts_with("CONNECTED") {
        return NetworkStatus::default();
    }
    let mut parts = line.splitn(4, '|');
    parts.next(); // "CONNECTED"
    let interface_type = parts.next().filter(|s| !s.is_empty()).map(|s| s.to_string());
    let name = parts.next().filter(|s| !s.is_empty()).map(|s| s.to_string());
    let local_ip = parts.next().filter(|s| !s.is_empty()).map(|s| s.to_string());
    NetworkStatus {
        connected: true,
        interface_type,
        name,
        local_ip,
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn network_status() -> NetworkStatus {
    NetworkStatus::default()
}

pub fn snapshot(sys: &mut System) -> SystemStats {
    sys.refresh_cpu_usage();
    sys.refresh_memory();

    let (disk_used_gb, disk_total_gb) = disk_usage_gb();
    let network = network_status();

    SystemStats {
        cpu_percent: sys.global_cpu_usage(),
        cpu_cores: sys.cpus().iter().map(|c| c.cpu_usage()).collect(),
        ram_used_mb: sys.used_memory() / 1_048_576,
        ram_total_mb: sys.total_memory() / 1_048_576,
        swap_used_mb: sys.used_swap() / 1_048_576,
        swap_total_mb: sys.total_swap() / 1_048_576,
        disk_used_gb,
        disk_total_gb,
        gpu_name: gpu_name(),
        gpu_percent: gpu_percent(),
        network_connected: network.connected,
        network_type: network.interface_type,
        network_name: network.name,
        network_local_ip: network.local_ip,
    }
}

#[tauri::command]
pub fn get_system_stats(state: tauri::State<SysState>) -> Result<SystemStats, String> {
    let mut sys = state.sys.lock().map_err(|e| e.to_string())?;
    Ok(snapshot(&mut sys))
}
