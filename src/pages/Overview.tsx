import { useCallback, useEffect, useRef, useState } from "react";
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
  Search,
  RefreshCw,
  X,
  ListChecks,
  PauseCircle,
  PlayCircle,
} from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import { Checkbox } from "@/components/ui/checkbox";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TargetFormDialog } from "@/components/target-form-dialog";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { PauseTargetDialog } from "@/components/pause-target-dialog";
import { cn, formatDateOnly, isPaused, pausedTooltip, rowStatus, type StatusFilter } from "@/lib/utils";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import type { TargetFormValues } from "@/lib/schemas";
import type { Target, TargetOverview } from "@/types/target";

const TARGET_DRAG_TYPE = "application/x-dkb-target-id";
const GROUP_DRAG_TYPE = "application/x-dkb-group-name";
const isMac = navigator.platform.toLowerCase().includes("mac");

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
  onCheckNow,
  checking,
  selectMode,
  selected,
  onToggleSelected,
  onPause,
  onResume,
}: {
  overview: TargetOverview;
  onEdit: (t: Target) => void;
  onDelete: (id: number) => void;
  onToggleEnabled: (target: Target, enabled: boolean) => void;
  onDropTarget: (draggedId: number, droppedOnId: number) => void;
  onCheckNow: (id: number) => void;
  checking: boolean;
  selectMode: boolean;
  selected: boolean;
  onToggleSelected: (id: number) => void;
  onPause: (target: Target) => void;
  onResume: (id: number) => void;
}) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { target, latest_check, ssl_status, uptime_24h_pct } = overview;
  const paused = isPaused(target);
  return (
    <div
      className={cn(
        "group flex cursor-pointer items-center gap-1 px-2 py-3 transition-colors hover:bg-accent/50",
        selected && "bg-accent/40",
      )}
      onClick={(e) => {
        // Base UI's Switch toggles by re-dispatching a second, independent
        // click event on its hidden checkbox input (so the browser fires a
        // real native "change" event) — that second click bubbles on its
        // own and isn't stopped by stopPropagation() on the original click,
        // so this checks where the click actually originated instead of
        // relying on propagation having been stopped upstream.
        if ((e.target as HTMLElement).closest("[data-stop-navigation]")) return;
        if (selectMode) {
          onToggleSelected(target.id);
          return;
        }
        navigate(`/targets/${target.id}`);
      }}
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes(TARGET_DRAG_TYPE)) e.preventDefault();
      }}
      onDrop={(e) => {
        const draggedId = Number(e.dataTransfer.getData(TARGET_DRAG_TYPE));
        if (draggedId && draggedId !== target.id) onDropTarget(draggedId, target.id);
      }}
    >
      {!selectMode && (
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
      )}

      {selectMode && (
        <span data-stop-navigation onClick={(e) => e.stopPropagation()} className="px-1">
          <Checkbox checked={selected} onCheckedChange={() => onToggleSelected(target.id)} />
        </span>
      )}

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
        ) : paused ? (
          <Badge variant="secondary" title={pausedTooltip(target.paused_until!, t)}>
            <PauseCircle className="size-3" />
            {t("overview.paused")}
          </Badge>
        ) : !latest_check ? (
          <Badge variant="secondary">{t("overview.status.unchecked")}</Badge>
        ) : latest_check.success ? (
          <Badge className="bg-success text-white">{t("overview.status.up")}</Badge>
        ) : (
          <Badge variant="destructive">{t("overview.status.down")}</Badge>
        )}

        {/* Base UI's Switch renders its hidden checkbox <input> as a SIBLING
            of the visible <span> it toggles (not a child of it) — the
            re-dispatched click this component fires on that input therefore
            has a target outside the <span>'s own subtree, so putting
            data-stop-navigation directly on <Switch> can't be found by the
            row's closest() check for that second click. Wrapping both in a
            span with the marker fixes it regardless of which of the two
            elements the click actually targets. */}
        <span data-stop-navigation onClick={(e) => e.stopPropagation()}>
          <Switch checked={target.enabled} onCheckedChange={(checked) => onToggleEnabled(target, checked)} />
        </span>

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
            <DropdownMenuItem disabled={checking} onClick={() => onCheckNow(target.id)}>
              <RefreshCw className={cn("size-3.5", checking && "animate-spin")} />
              {t("overview.checkNow")}
            </DropdownMenuItem>
            {paused ? (
              <DropdownMenuItem onClick={() => onResume(target.id)}>
                <PlayCircle className="size-3.5" />
                {t("overview.resume")}
              </DropdownMenuItem>
            ) : (
              <DropdownMenuItem onClick={() => onPause(target)}>
                <PauseCircle className="size-3.5" />
                {t("overview.pause")}
              </DropdownMenuItem>
            )}
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
  const [search, setSearch] = useState("");
  const [statusFilters, setStatusFilters] = useState<Set<StatusFilter>>(new Set());
  const [checkingIds, setCheckingIds] = useState<Set<number>>(new Set());
  const [checkingAll, setCheckingAll] = useState(false);
  const [selectMode, setSelectMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set());
  const [pendingDelete, setPendingDelete] = useState<{ ids: number[]; name?: string } | null>(null);
  const [pendingPause, setPendingPause] = useState<Target | null>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);

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

  // Cmd+K on macOS / Ctrl+K elsewhere focuses the search box, clearing any
  // active multi-select first since the two occupy the same toolbar slot.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setSelectMode(false);
        setSelectedIds(new Set());
        requestAnimationFrame(() => searchInputRef.current?.focus());
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  const handleAdd = () => {
    setEditingTarget(null);
    setDialogOpen(true);
  };

  const handleEdit = (target: Target) => {
    setEditingTarget(target);
    setDialogOpen(true);
  };

  const handleDelete = (id: number) => {
    const name = overview.find((o) => o.target.id === id)?.target.name;
    setPendingDelete({ ids: [id], name });
  };

  const confirmDelete = async () => {
    if (!pendingDelete) return;
    const { ids } = pendingDelete;
    try {
      if (ids.length === 1) {
        await api.deleteTarget(ids[0]);
        toast.success(t("toast.deleteSuccess"));
      } else {
        await api.deleteTargets(ids);
        toast.success(t("toast.deleteSelectedSuccess"));
      }
      setSelectedIds((prev) => {
        const next = new Set(prev);
        ids.forEach((id) => next.delete(id));
        return next;
      });
      load();
    } catch (err) {
      toast.error(`${t("toast.deleteFailed")}: ${String(err)}`);
    }
  };

  const handleCheckNow = async (id: number) => {
    setCheckingIds((prev) => new Set(prev).add(id));
    try {
      await api.checkTargetNow(id);
      toast.success(t("toast.checkNowSuccess"));
      load();
    } catch (err) {
      toast.error(`${t("toast.checkNowFailed")}: ${String(err)}`);
    } finally {
      setCheckingIds((prev) => {
        const next = new Set(prev);
        next.delete(id);
        return next;
      });
    }
  };

  const handleCheckAllNow = async () => {
    setCheckingAll(true);
    try {
      await api.checkAllNow();
      toast.success(t("toast.checkAllNowSuccess"));
      load();
    } catch (err) {
      toast.error(`${t("toast.checkAllNowFailed")}: ${String(err)}`);
    } finally {
      setCheckingAll(false);
    }
  };

  const handleConfirmPause = async (minutes?: number) => {
    if (!pendingPause) return;
    try {
      await api.pauseTarget(pendingPause.id, minutes);
      load();
    } catch (err) {
      toast.error(`${t("toast.pauseFailed")}: ${String(err)}`);
    }
  };

  const handleResume = async (id: number) => {
    try {
      await api.resumeTarget(id);
      load();
    } catch (err) {
      toast.error(`${t("toast.resumeFailed")}: ${String(err)}`);
    }
  };

  const handleCheckSelected = async () => {
    const ids = [...selectedIds];
    setCheckingIds((prev) => new Set([...prev, ...ids]));
    try {
      await Promise.all(ids.map((id) => api.checkTargetNow(id)));
      toast.success(t("toast.checkAllNowSuccess"));
      load();
    } catch (err) {
      toast.error(`${t("toast.checkAllNowFailed")}: ${String(err)}`);
    } finally {
      setCheckingIds((prev) => {
        const next = new Set(prev);
        ids.forEach((id) => next.delete(id));
        return next;
      });
    }
  };

  const handleSetSelectedEnabled = async (enabled: boolean) => {
    const ids = [...selectedIds];
    try {
      await api.setTargetsEnabled(ids, enabled);
      load();
    } catch (err) {
      const key = enabled ? "toast.enableSelectedFailed" : "toast.disableSelectedFailed";
      toast.error(`${t(key)}: ${String(err)}`);
    }
  };

  const toggleSelected = (id: number) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
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

  const searchQuery = search.trim().toLowerCase();
  const matchesSearch = (row: TargetOverview) =>
    !searchQuery ||
    row.target.name.toLowerCase().includes(searchQuery) ||
    row.target.url.toLowerCase().includes(searchQuery);

  const matchesFilter = (row: TargetOverview) => statusFilters.size === 0 || statusFilters.has(rowStatus(row));
  const matchesRow = (row: TargetOverview) => matchesSearch(row) && matchesFilter(row);

  const statusCounts = overview.reduce(
    (counts, row) => {
      counts[rowStatus(row)]++;
      return counts;
    },
    { up: 0, down: 0, unchecked: 0, disabled: 0, paused: 0 } as Record<StatusFilter, number>,
  );

  const toggleStatusFilter = (status: StatusFilter) => {
    setStatusFilters((prev) => {
      const next = new Set(prev);
      if (next.has(status)) next.delete(status);
      else next.add(status);
      return next;
    });
  };

  const visibleIds = overview.filter(matchesRow).map((o) => o.target.id);
  const allVisibleSelected = visibleIds.length > 0 && visibleIds.every((id) => selectedIds.has(id));
  const toggleSelectAll = () => {
    setSelectedIds((prev) => {
      if (allVisibleSelected) {
        const next = new Set(prev);
        visibleIds.forEach((id) => next.delete(id));
        return next;
      }
      return new Set([...prev, ...visibleIds]);
    });
  };

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
        <div className="group flex items-center gap-2">
          <h1 className="text-lg font-semibold tracking-tight">{t("overview.title")}</h1>
          {totalCount > 0 && (
            <Badge
              variant="secondary"
              className={cn(upCount === totalCount ? "text-success" : "text-destructive")}
            >
              {upCount}/{totalCount} {t("overview.upSummary")}
            </Badge>
          )}
          {overview.length > 0 && (
            <Button
              variant="ghost"
              size="icon-sm"
              title={t("overview.checkAllNow")}
              onClick={handleCheckAllNow}
              disabled={checkingAll}
              className={cn(
                "opacity-0 transition-opacity group-hover:opacity-100",
                checkingAll && "opacity-100",
              )}
            >
              <RefreshCw className={cn("size-4", checkingAll && "animate-spin")} />
            </Button>
          )}
        </div>
        <div className="flex items-center gap-2">
          {overview.length > 0 && (
            <Button
              variant="outline"
              onClick={() => {
                if (selectMode) setSelectedIds(new Set());
                setSelectMode((v) => !v);
              }}
            >
              {selectMode ? <X className="size-4" /> : <ListChecks className="size-4" />}
              {selectMode ? t("common.cancel") : t("overview.select")}
            </Button>
          )}
          <Button onClick={handleAdd}>
            <Plus className="size-4" />
            {t("overview.addTarget")}
          </Button>
        </div>
      </div>

      {overview.length > 0 && (
        <div className="flex items-center gap-2">
          {selectMode && (
            <span className="flex shrink-0 items-center pl-1">
              <Checkbox checked={allVisibleSelected} onCheckedChange={toggleSelectAll} />
            </span>
          )}
          <div className="relative flex-1">
            <Search className="pointer-events-none absolute top-1/2 left-3.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
            <input
              ref={searchInputRef}
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={t("overview.searchPlaceholder")}
              className="h-9 w-full rounded-full border border-input bg-input/20 pr-9 pl-9 text-sm outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50"
            />
            {search ? (
              <button
                type="button"
                onClick={() => {
                  setSearch("");
                  searchInputRef.current?.focus();
                }}
                className="absolute top-1/2 right-2.5 -translate-y-1/2 text-muted-foreground hover:text-foreground"
              >
                <X className="size-3.5" />
              </button>
            ) : (
              <kbd className="pointer-events-none absolute top-1/2 right-3 -translate-y-1/2 text-[11px] font-medium text-muted-foreground">
                {isMac ? "⌘K" : "Ctrl K"}
              </kbd>
            )}
          </div>
        </div>
      )}

      {overview.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5">
          {(
            [
              ["up", t("overview.status.up")],
              ["down", t("overview.status.down")],
              ["unchecked", t("overview.status.unchecked")],
              ["paused", t("overview.paused")],
              ["disabled", t("overview.status.disabled")],
            ] as [StatusFilter, string][]
          )
            .filter(([status]) => statusCounts[status] > 0)
            .map(([status, label]) => {
              const active = statusFilters.has(status);
              return (
                <button
                  key={status}
                  type="button"
                  onClick={() => toggleStatusFilter(status)}
                  className={cn(
                    "flex items-center gap-1 rounded-full border px-2.5 py-1 text-xs font-medium transition-colors",
                    active
                      ? "border-primary bg-primary text-primary-foreground"
                      : "border-border bg-transparent text-muted-foreground hover:bg-accent/50",
                  )}
                >
                  {label}
                  <span className={cn("tabular-nums", active ? "text-primary-foreground/80" : "text-muted-foreground/70")}>
                    {statusCounts[status]}
                  </span>
                </button>
              );
            })}
          {statusFilters.size > 0 && (
            <button
              type="button"
              onClick={() => setStatusFilters(new Set())}
              className="text-xs text-muted-foreground hover:text-foreground hover:underline"
            >
              {t("overview.clearFilters")}
            </button>
          )}
        </div>
      )}

      {selectMode && selectedIds.size > 0 && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg border border-border bg-card px-3 py-2">
          <span className="text-xs font-medium text-muted-foreground">
            {t("overview.selectedCount", { count: selectedIds.size })}
          </span>
          <Button variant="outline" size="sm" onClick={handleCheckSelected}>
            <RefreshCw className="size-3.5" />
            {t("overview.checkNow")}
          </Button>
          <Button variant="outline" size="sm" onClick={() => handleSetSelectedEnabled(true)}>
            {t("overview.enableSelected")}
          </Button>
          <Button variant="outline" size="sm" onClick={() => handleSetSelectedEnabled(false)}>
            {t("overview.disableSelected")}
          </Button>
          <Button variant="destructive" size="sm" onClick={() => setPendingDelete({ ids: [...selectedIds] })}>
            <Trash2 className="size-3.5" />
            {t("overview.deleteSelected")}
          </Button>
          <Button variant="ghost" size="sm" onClick={() => setSelectedIds(new Set())}>
            {t("overview.clearSelection")}
          </Button>
        </div>
      )}

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
      ) : (searchQuery || statusFilters.size > 0) && !overview.some(matchesRow) ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-2 rounded-2xl border border-dashed border-border py-16 text-center">
          <p className="text-sm text-muted-foreground">{t("overview.noSearchResults")}</p>
        </div>
      ) : (
        orderedGroupNames.map((group) => {
          const rows = grouped.get(group) ?? [];
          const visibleRows = rows.filter(matchesRow);
          if (visibleRows.length === 0) return null;
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
                {visibleRows.map((row) => (
                  <TargetRow
                    key={row.target.id}
                    overview={row}
                    onEdit={handleEdit}
                    onDelete={handleDelete}
                    onToggleEnabled={handleToggleEnabled}
                    onDropTarget={handleDropTarget}
                    onCheckNow={handleCheckNow}
                    checking={checkingIds.has(row.target.id)}
                    selectMode={selectMode}
                    selected={selectedIds.has(row.target.id)}
                    onToggleSelected={toggleSelected}
                    onPause={setPendingPause}
                    onResume={handleResume}
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

      <ConfirmDialog
        open={pendingDelete !== null}
        onOpenChange={(open) => !open && setPendingDelete(null)}
        title={t("common.confirmTitle")}
        description={
          pendingDelete
            ? pendingDelete.ids.length === 1
              ? t("overview.deleteConfirm", { name: pendingDelete.name ?? "" })
              : t("overview.deleteSelectedConfirm", { count: pendingDelete.ids.length })
            : ""
        }
        confirmLabel={t("common.delete")}
        onConfirm={confirmDelete}
      />

      <PauseTargetDialog
        open={pendingPause !== null}
        onOpenChange={(open) => !open && setPendingPause(null)}
        targetName={pendingPause?.name}
        onPause={handleConfirmPause}
      />
    </div>
  );
}
