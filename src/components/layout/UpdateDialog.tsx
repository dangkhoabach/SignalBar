import { useCallback, useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useTranslation } from "@/lib/i18n/context";

type Phase = "available" | "downloading" | "ready" | "error";

export function UpdateDialog() {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [phase, setPhase] = useState<Phase>("available");
  const [update, setUpdate] = useState<Update | null>(null);
  const [progress, setProgress] = useState(0);
  const [errorMessage, setErrorMessage] = useState("");

  const runCheck = useCallback(
    async (silent: boolean) => {
      try {
        const result = await check();
        if (!result) {
          if (!silent) toast.info(t("update.upToDate"));
          return;
        }
        setUpdate(result);
        setPhase("available");
        setOpen(true);
      } catch (err) {
        // A silent (startup) check failing is usually just no network yet —
        // don't nag the user every launch. A manual check still reports it.
        if (!silent) toast.error(`${t("update.checkFailed")}: ${String(err)}`);
      }
    },
    [t],
  );

  useEffect(() => {
    // Check once automatically when the app opens.
    runCheck(true);

    const unlisten = listen("check-update-clicked", () => {
      runCheck(false);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleInstall = async () => {
    if (!update) return;
    setPhase("downloading");
    setProgress(0);
    let total = 0;
    let downloaded = 0;
    try {
      await update.downloadAndInstall((event) => {
        switch (event.event) {
          case "Started":
            total = event.data.contentLength ?? 0;
            break;
          case "Progress":
            downloaded += event.data.chunkLength;
            setProgress(total > 0 ? Math.min(100, Math.round((downloaded / total) * 100)) : 0);
            break;
          case "Finished":
            setProgress(100);
            break;
        }
      });
      setPhase("ready");
    } catch (err) {
      setErrorMessage(String(err));
      setPhase("error");
    }
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        // Downloading/ready shouldn't be dismissable by clicking outside —
        // an install in progress or a pending restart needs an explicit choice.
        if (phase === "downloading" || phase === "ready") return;
        setOpen(next);
      }}
    >
      <DialogContent showCloseButton={phase === "available" || phase === "error"}>
        <DialogHeader>
          <DialogTitle>
            {phase === "ready" ? t("update.readyTitle") : t("update.availableTitle")}
          </DialogTitle>
          {phase === "available" && update && (
            <DialogDescription>
              {t("update.newVersion")} {update.version} ({t("update.currentVersion")} {update.currentVersion})
            </DialogDescription>
          )}
          {phase === "downloading" && <DialogDescription>{t("update.downloading")}</DialogDescription>}
          {phase === "ready" && <DialogDescription>{t("update.readyDesc")}</DialogDescription>}
          {phase === "error" && <DialogDescription>{errorMessage}</DialogDescription>}
        </DialogHeader>

        {phase === "available" && update?.body && (
          <p className="max-h-40 overflow-y-auto whitespace-pre-wrap rounded-lg bg-muted/50 p-3 text-xs text-muted-foreground">
            {update.body}
          </p>
        )}

        {phase === "downloading" && (
          <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
            <div
              className="h-full rounded-full bg-primary transition-all"
              style={{ width: `${progress}%` }}
            />
          </div>
        )}

        <DialogFooter>
          {phase === "available" && (
            <>
              <Button variant="outline" onClick={() => setOpen(false)}>
                {t("update.later")}
              </Button>
              <Button onClick={handleInstall}>{t("update.installNow")}</Button>
            </>
          )}
          {phase === "ready" && <Button onClick={() => relaunch()}>{t("update.restartNow")}</Button>}
          {phase === "error" && (
            <Button variant="outline" onClick={() => setOpen(false)}>
              {t("update.close")}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
