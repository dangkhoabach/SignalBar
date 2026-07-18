import { useEffect, useState } from "react";
import { getVersion } from "@tauri-apps/api/app";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog";
import appIcon from "@/app-icon.png";

export function AboutDialog() {
  const [open, setOpen] = useState(false);
  const [version, setVersion] = useState("");

  useEffect(() => {
    const unlisten = listen("show-about-clicked", () => {
      getVersion().then(setVersion).catch(() => {});
      setOpen(true);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent className="flex flex-col items-center gap-3 py-6 text-center sm:max-w-xs">
        <img src={appIcon} alt="" className="size-16 rounded-2xl" />
        <DialogTitle className="text-base font-semibold">DKB Monitor</DialogTitle>
        <span className="text-xs text-muted-foreground">Version {version}</span>
        <p className="text-xs text-muted-foreground">
          Designed & Developed by{" "}
          <button
            type="button"
            onClick={() => openUrl("https://dangkhoabach.vn")}
            className="font-medium text-foreground transition-colors hover:text-primary"
          >
            dangkhoabach
          </button>
        </p>
      </DialogContent>
    </Dialog>
  );
}
