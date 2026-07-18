import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { listen } from "@tauri-apps/api/event";
import {
  Plus,
  Trash2,
  Pencil,
  Globe,
  ShieldCheck,
  Clock,
  MoreVertical,
  GripVertical,
} from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TargetFormDialog } from "@/components/target-form-dialog";
import { cn, formatDateOnly } from "@/lib/utils";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import type { TargetFormValues } from "@/lib/schemas";
import type { Target, TargetOverview } from "@/types/target";

const TARGET_DRAG_TYPE = "application/x-dkb-target-id";
const GROUP_DRAG_TYPE = "application/x-dkb-group-name";

function StatusDot({ overview }: { overview: TargetOverview }) {
  if (!overview.latest_check) {
    return <span className="size-2.5 rounded-full bg-muted-foreground/40" />;
  }
  return (
    <span
      className={cn(
        "size-2.5 rounded-full",
        overview.latest_check.success ? "bg-success" : "bg-destructive",
      )}
    />
  );
}

function TargetRow({
  overview,
  onEdit,
  onDelete,
  onToggleEnabled,
  onDropTarget,
}: {
  overview: TargetOverview;
  onEdit: (t: Target) => void;
  onDelete: (id: number) => void;
  onToggleEnabled: (target: Target, enabled: boolean) => void;
  onDropTarget: (draggedId: number, droppedOnId: number) => void;
}) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { target, latest_check, ssl_status, uptime_24h_pct } = overview;
  return (
    <div
      className="group flex cursor-pointer items-center gap-1 px-2 py-3 transition-colors hover:bg-accent/50"
      onClick={() => navigate(`/targets/${target.id}`)}
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes(TARGET_DRAG_TYPE)) e.preventDefault();
      }}
      onDrop={(e) => {
        const draggedId = Number(e.dataTransfer.getData(TARGET_DRAG_TYPE));
        if (draggedId && draggedId !== target.id) onDropTarget(draggedId, target.id);
      }}
    >
      <span
        draggable
        onClick={(e) => e.stopPropagation()}
        onDragStart={(e) => {
          e.dataTransfer.effectAllowed = "move";
          e.dataTransfer.setData(TARGET_DRAG_TYPE, String(target.id));
        }}
        className="cursor-grab touch-none px-1 text-muted-foreground/50 opacity-0 transition-opacity group-hover:opacity-100"
      >
        <GripVertical className="size-3.5" />
      </span>

      <StatusDot overview={overview} />

      <div className={cn("flex min-w-0 flex-1 flex-col px-2", !target.enabled && "opacity-50")}>
        <span className="truncate text-sm font-medium">{target.name}</span>
        <span className="truncate text-xs text-muted-foreground">{target.url}</span>
      </div>

      <div className="flex items-center gap-4">
        {target.enabled && (
          <div className="hidden items-center gap-4 text-xs text-muted-foreground sm:flex">
            {uptime_24h_pct != null && (
              <span className="flex items-center gap-1">
                <Globe className="size-3.5" />
                {uptime_24h_pct.toFixed(0)}% {t("overview.uptime")}
              </span>
            )}
            {latest_check?.response_time_ms != null && (
              <span className="flex items-center gap-1">
                <Clock className="size-3.5" />
                {latest_check.response_time_ms}ms
              </span>
            )}
            {ssl_status?.expiry_date && (
              <span className="flex items-center gap-1">
                <ShieldCheck className="size-3.5" />
                {formatDateOnly(ssl_status.expiry_date)}
              </span>
            )}
          </div>
        )}

        {!target.enabled ? (
          <Badge variant="secondary">{t("overview.status.disabled")}</Badge>
        ) : !latest_check ? (
          <Badge variant="secondary">{t("overview.status.unchecked")}</Badge>
        ) : latest_check.success ? (
          <Badge className="bg-success text-white">{t("overview.status.up")}</Badge>
        ) : (
          <Badge variant="destructive">{t("overview.status.down")}</Badge>
        )}

        <Switch
          checked={target.enabled}
          onCheckedChange={(checked) => onToggleEnabled(target, checked)}
          onClick={(e) => e.stopPropagation()}
        />

        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                variant="ghost"
                size="icon-sm"
                className="opacity-0 transition-opacity group-hover:opacity-100"
                onClick={(e) => e.stopPropagation()}
              />
            }
          >
            <MoreVertical className="size-3.5" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" onClick={(e) => e.stopPropagation()}>
            <DropdownMenuItem onClick={() => onEdit(target)}>
              <Pencil className="size-3.5" />
              {t("overview.edit")}
            </DropdownMenuItem>
            <DropdownMenuItem variant="destructive" onClick={() => onDelete(target.id)}>
              <Trash2 className="size-3.5" />
              {t("overview.delete")}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </div>
  );
}

function groupByTag(overview: TargetOverview[]): Map<string, TargetOverview[]> {
  const groups = new Map<string, TargetOverview[]>();
  for (const row of overview) {
    const key = row.target.group_tag || "—";
    const list = groups.get(key);
    if (list) {
      list.push(row);
    } else {
      groups.set(key, [row]);
    }
  }
  return groups;
}

function orderGroupNames(names: string[], savedOrder: string[]): string[] {
  const known = savedOrder.filter((g) => names.includes(g));
  const unknown = names.filter((g) => !savedOrder.includes(g)).sort((a, b) => a.localeCompare(b));
  return [...known, ...unknown];
}

function moveBefore<T>(items: T[], moved: T, target: T): T[] {
  const withoutMoved = items.filter((item) => item !== moved);
  const targetIndex = withoutMoved.indexOf(target);
  withoutMoved.splice(targetIndex, 0, moved);
  return withoutMoved;
}

export function OverviewPage() {
  const { t } = useTranslation();
  const [overview, setOverview] = useState<TargetOverview[]>([]);
  const [groupOrder, setGroupOrder] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingTarget, setEditingTarget] = useState<Target | null>(null);

  const load = useCallback(async () => {
    try {
      const [data, order] = await Promise.all([api.getOverview(), api.getGroupOrder()]);
      setOverview(data);
      setGroupOrder(order);
    } catch (err) {
      toast.error(`${t("toast.loadFailed")}: ${String(err)}`);
    } finally {
      setLoading(false);
    }
  }, [t]);

  useEffect(() => {
    load();
    const unlisten = listen("overview-updated", () => load());
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [load]);

  const handleAdd = () => {
    setEditingTarget(null);
    setDialogOpen(true);
  };

  const handleEdit = (target: Target) => {
    setEditingTarget(target);
    setDialogOpen(true);
  };

  const handleDelete = async (id: number) => {
    try {
      await api.deleteTarget(id);
      toast.success(t("toast.deleteSuccess"));
      load();
    } catch (err) {
      toast.error(`${t("toast.deleteFailed")}: ${String(err)}`);
    }
  };

  const handleToggleEnabled = async (target: Target, enabled: boolean) => {
    try {
      await api.updateTarget({
        id: target.id,
        name: target.name,
        url: target.url,
        group_tag: target.group_tag,
        check_interval_secs: target.check_interval_secs,
        enabled,
        check_http: target.check_http,
        expected_status: target.expected_status,
        check_ssl: target.check_ssl,
        check_domain: target.check_domain,
        custom_path: target.custom_path,
        expected_body_contains: target.expected_body_contains,
      });
      load();
    } catch (err) {
      toast.error(`${t("toast.saveFailed")}: ${String(err)}`);
    }
  };

  const handleSubmit = async (values: TargetFormValues) => {
    const payload = {
      name: values.name,
      url: values.url,
      group_tag: values.group_tag || null,
      check_interval_secs: values.check_interval_secs,
      check_http: values.check_http,
      expected_status: values.expected_status,
      check_ssl: values.check_ssl,
      check_domain: values.check_domain,
      custom_path: values.custom_path || null,
      expected_body_contains: values.expected_body_contains || null,
    };
    try {
      if (editingTarget) {
        await api.updateTarget({ ...payload, id: editingTarget.id, enabled: editingTarget.enabled });
        toast.success(t("toast.updateSuccess"));
      } else {
        await api.addTarget(payload);
        toast.success(t("toast.addSuccess"));
      }
      load();
    } catch (err) {
      toast.error(`${t("toast.saveFailed")}: ${String(err)}`);
    }
  };

  const grouped = groupByTag(overview);
  const orderedGroupNames = orderGroupNames([...grouped.keys()], groupOrder);

  const enabledTargets = overview.filter((o) => o.target.enabled);
  const upCount = enabledTargets.filter((o) => o.latest_check?.success).length;
  const totalCount = enabledTargets.length;

  const handleDropTarget = async (draggedId: number, droppedOnId: number) => {
    const group = [...grouped.values()].find((rows) => rows.some((r) => r.target.id === draggedId));
    if (!group || !group.some((r) => r.target.id === droppedOnId)) return;
    const ids = group.map((r) => r.target.id);
    const newIds = moveBefore(ids, draggedId, droppedOnId);

    // Keep every row's current array slot, just swap in the new order for
    // the slots that belong to this group so unrelated groups don't shift.
    setOverview((prev) => {
      const idToRow = new Map(prev.map((r) => [r.target.id, r]));
      const newRowsForGroup = newIds.map((id) => idToRow.get(id)!);
      let cursor = 0;
      return prev.map((r) => (ids.includes(r.target.id) ? newRowsForGroup[cursor++] : r));
    });

    try {
      await api.reorderTargets(newIds);
    } catch (err) {
      toast.error(`${t("toast.saveFailed")}: ${String(err)}`);
      load();
    }
  };

  const [editingGroup, setEditingGroup] = useState<string | null>(null);
  const [editingGroupValue, setEditingGroupValue] = useState("");

  const startRenameGroup = (group: string) => {
    setEditingGroup(group);
    setEditingGroupValue(group);
  };

  const commitRenameGroup = async () => {
    const oldName = editingGroup;
    const newName = editingGroupValue.trim();
    setEditingGroup(null);
    if (!oldName || !newName || newName === oldName) return;
    try {
      await api.renameGroup(oldName, newName);
      load();
    } catch (err) {
      toast.error(`${t("toast.saveFailed")}: ${String(err)}`);
    }
  };

  const handleDropGroup = async (draggedGroup: string, droppedOnGroup: string) => {
    if (draggedGroup === droppedOnGroup) return;
    const newOrder = moveBefore(orderedGroupNames, draggedGroup, droppedOnGroup);
    setGroupOrder(newOrder);
    try {
      await api.setGroupOrder(newOrder);
    } catch (err) {
      toast.error(`${t("toast.saveFailed")}: ${String(err)}`);
      load();
    }
  };

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-6 pt-11 pb-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <h1 className="text-lg font-semibold tracking-tight">{t("overview.title")}</h1>
          {totalCount > 0 && (
            <Badge
              variant="secondary"
              className={cn(upCount === totalCount ? "text-success" : "text-destructive")}
            >
              {upCount}/{totalCount} {t("overview.upSummary")}
            </Badge>
          )}
        </div>
        <Button onClick={handleAdd}>
          <Plus className="size-4" />
          {t("overview.addTarget")}
        </Button>
      </div>

      {loading ? (
        <p className="text-sm text-muted-foreground">{t("overview.loading")}</p>
      ) : overview.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 rounded-2xl border border-dashed border-border py-16 text-center">
          <p className="text-sm text-muted-foreground">{t("overview.empty")}</p>
          <Button variant="outline" onClick={handleAdd}>
            <Plus className="size-4" />
            {t("overview.addFirstTarget")}
          </Button>
        </div>
      ) : (
        orderedGroupNames.map((group) => {
          const rows = grouped.get(group) ?? [];
          return (
            <div
              key={group}
              className="flex flex-col gap-2"
              onDragOver={(e) => {
                if (e.dataTransfer.types.includes(GROUP_DRAG_TYPE)) e.preventDefault();
              }}
              onDrop={(e) => {
                const draggedGroup = e.dataTransfer.getData(GROUP_DRAG_TYPE);
                if (draggedGroup) handleDropGroup(draggedGroup, group);
              }}
            >
              <div className="group/header flex items-center gap-1 px-1">
                <span
                  draggable
                  onDragStart={(e) => {
                    e.dataTransfer.effectAllowed = "move";
                    e.dataTransfer.setData(GROUP_DRAG_TYPE, group);
                  }}
                  className="cursor-grab text-muted-foreground/50"
                >
                  <GripVertical className="size-3" />
                </span>
                {editingGroup === group ? (
                  <input
                    autoFocus
                    value={editingGroupValue}
                    onChange={(e) => setEditingGroupValue(e.target.value)}
                    onBlur={commitRenameGroup}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") e.currentTarget.blur();
                      if (e.key === "Escape") setEditingGroup(null);
                    }}
                    className="rounded border border-input bg-transparent px-1 text-xs font-medium tracking-wide text-foreground uppercase outline-none"
                  />
                ) : (
                  <span className="text-xs font-medium tracking-wide text-muted-foreground uppercase">
                    {group}
                  </span>
                )}
                {group !== "—" && editingGroup !== group && (
                  <button
                    type="button"
                    onClick={() => startRenameGroup(group)}
                    className="text-muted-foreground/50 opacity-0 transition-opacity group-hover/header:opacity-100 hover:text-foreground"
                  >
                    <Pencil className="size-3" />
                  </button>
                )}
              </div>
              <div className="overflow-hidden rounded-2xl border border-border bg-card divide-y divide-border">
                {rows.map((row) => (
                  <TargetRow
                    key={row.target.id}
                    overview={row}
                    onEdit={handleEdit}
                    onDelete={handleDelete}
                    onToggleEnabled={handleToggleEnabled}
                    onDropTarget={handleDropTarget}
                  />
                ))}
              </div>
            </div>
          );
        })
      )}

      <TargetFormDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        editingTarget={editingTarget}
        onSubmit={handleSubmit}
      />
    </div>
  );
}
