import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useTranslation } from "@/lib/i18n/context";

const DURATIONS = [
  { minutes: 30, labelKey: "overview.pause30m" as const },
  { minutes: 60, labelKey: "overview.pause1h" as const },
  { minutes: 240, labelKey: "overview.pause4h" as const },
  { minutes: 1440, labelKey: "overview.pause24h" as const },
];

export function PauseTargetDialog({
  open,
  onOpenChange,
  targetName,
  onPause,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  targetName: string | undefined;
  onPause: (minutes?: number) => void;
}) {
  const { t } = useTranslation();

  const choose = (minutes?: number) => {
    onOpenChange(false);
    onPause(minutes);
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("overview.pauseDialogTitle")}</DialogTitle>
          <DialogDescription>{t("overview.pauseDialogDesc", { name: targetName ?? "" })}</DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-2 gap-2">
          {DURATIONS.map(({ minutes, labelKey }) => (
            <Button key={minutes} variant="outline" onClick={() => choose(minutes)}>
              {t(labelKey)}
            </Button>
          ))}
        </div>
        <Button variant="outline" onClick={() => choose(undefined)}>
          {t("overview.pauseUntilResumed")}
        </Button>
      </DialogContent>
    </Dialog>
  );
}
