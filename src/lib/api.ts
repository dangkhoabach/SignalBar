import { invoke } from "@tauri-apps/api/core";
import type {
  CheckResult,
  NewTarget,
  Target,
  TargetDetail,
  TargetOverview,
  UpdateTarget,
} from "@/types/target";
import type { AppSettings, UpdateSettingsInput } from "@/types/settings";
import type { SystemStats } from "@/types/system";

export const api = {
  listTargets: () => invoke<Target[]>("list_targets"),
  addTarget: (target: NewTarget) => invoke<Target>("add_target", { target }),
  updateTarget: (target: UpdateTarget) => invoke<Target>("update_target", { target }),
  deleteTarget: (id: number) => invoke<void>("delete_target", { id }),
  getHistory: (targetId: number, limit = 50) =>
    invoke<CheckResult[]>("get_history", { targetId, limit }),
  getOverview: () => invoke<TargetOverview[]>("get_overview"),
  getTargetDetail: (targetId: number) => invoke<TargetDetail>("get_target_detail", { targetId }),
  reorderTargets: (ids: number[]) => invoke<void>("reorder_targets", { ids }),
  getSettings: () => invoke<AppSettings>("get_settings"),
  updateSettings: (settings: UpdateSettingsInput) => invoke<AppSettings>("update_settings", { settings }),
  saveSmtpPassword: (password: string) => invoke<void>("save_smtp_password", { password }),
  clearSmtpPassword: () => invoke<void>("clear_smtp_password"),
  sendTestEmail: () => invoke<void>("send_test_email"),
  getGroupOrder: () => invoke<string[]>("get_group_order"),
  setGroupOrder: (order: string[]) => invoke<void>("set_group_order", { order }),
  getSystemStats: () => invoke<SystemStats>("get_system_stats"),
};
