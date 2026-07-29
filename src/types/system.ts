export interface SystemStats {
  cpu_percent: number;
  cpu_cores: number[];
  ram_used_mb: number;
  ram_total_mb: number;
  swap_used_mb: number;
  swap_total_mb: number;
  disk_used_gb: number;
  disk_total_gb: number;
  gpu_name: string | null;
  gpu_percent: number | null;
  network_connected: boolean;
  network_type: string | null;
  network_name: string | null;
  network_local_ip: string | null;
  network_download_kbps: number;
  network_upload_kbps: number;
  cpu_temp_celsius: number | null;
  battery_percent: number | null;
  battery_charging: boolean | null;
  uptime_secs: number;
  fan_rpms: number[];
}
