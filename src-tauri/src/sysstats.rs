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

#[cfg(not(target_os = "macos"))]
fn gpu_name() -> Option<String> {
    None
}

#[cfg(not(target_os = "macos"))]
fn gpu_percent() -> Option<f32> {
    None
}

pub fn snapshot(sys: &mut System) -> SystemStats {
    sys.refresh_cpu_usage();
    sys.refresh_memory();

    let (disk_used_gb, disk_total_gb) = disk_usage_gb();

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
    }
}

#[tauri::command]
pub fn get_system_stats(state: tauri::State<SysState>) -> Result<SystemStats, String> {
    let mut sys = state.sys.lock().map_err(|e| e.to_string())?;
    Ok(snapshot(&mut sys))
}
