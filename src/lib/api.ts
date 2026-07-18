import { invoke } from "@tauri-apps/api/core";
import type {
  CheckResult,
  NewTarget,
  Target,
  TargetOverview,
  UpdateTarget,
} from "@/types/target";

export const api = {
  listTargets: () => invoke<Target[]>("list_targets"),
  addTarget: (target: NewTarget) => invoke<Target>("add_target", { target }),
  updateTarget: (target: UpdateTarget) => invoke<Target>("update_target", { target }),
  deleteTarget: (id: number) => invoke<void>("delete_target", { id }),
  getHistory: (targetId: number, limit = 50) =>
    invoke<CheckResult[]>("get_history", { targetId, limit }),
  getOverview: () => invoke<TargetOverview[]>("get_overview"),
};
