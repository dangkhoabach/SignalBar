import { useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { api } from "@/lib/api";
import { useTranslation } from "@/lib/i18n/context";
import type { Target } from "@/types/target";

export function ExportDomainsDialog({
  open,
  onOpenChange,
  onExport,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onExport: (ids?: number[]) => Promise<void>;
}) {
  const { t } = useTranslation();
  const [targets, setTargets] = useState<Target[]>([]);
  const [selectedIds, setSelectedIds] = useState<Set<number>>(new Set());
  const [exporting, setExporting] = useState(false);

  useEffect(() => {
    if (!open) return;
    api.listTargets().then((list) => {
      setTargets(list);
      setSelectedIds(new Set(list.map((t) => t.id)));
    });
  }, [open]);

  const allSelected = targets.length > 0 && selectedIds.size === targets.length;

  const toggleAll = () => {
    setSelectedIds(allSelected ? new Set() : new Set(targets.map((t) => t.id)));
  };

  const toggleOne = (id: number) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const handleExport = async () => {
    if (selectedIds.size === 0) {
      toast.error(t("settings.exportNoneSelected"));
      return;
    }
    setExporting(true);
    try {
      const ids = allSelected ? undefined : [...selectedIds];
      await onExport(ids);
      onOpenChange(false);
    } finally {
      setExporting(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("settings.exportDialogTitle")}</DialogTitle>
          <DialogDescription>{t("settings.exportDialogDesc")}</DialogDescription>
        </DialogHeader>

        <div className="flex max-h-72 flex-col gap-1 overflow-y-auto">
          <label className="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm font-medium hover:bg-accent/50">
            <Checkbox checked={allSelected} onCheckedChange={toggleAll} />
            {allSelected ? t("common.deselectAll") : t("common.selectAll")}
          </label>
          <div className="my-1 h-px bg-border" />
          {targets.map((target) => (
            <label
              key={target.id}
              className="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-accent/50"
            >
              <Checkbox checked={selectedIds.has(target.id)} onCheckedChange={() => toggleOne(target.id)} />
              <span className="flex min-w-0 flex-col">
                <span className="truncate font-medium">{target.name}</span>
                <span className="truncate text-xs text-muted-foreground">{target.url}</span>
              </span>
            </label>
          ))}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {t("common.cancel")}
          </Button>
          <Button onClick={handleExport} disabled={exporting}>
            {t("common.export")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
