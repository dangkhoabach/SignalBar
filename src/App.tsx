import { useEffect } from "react";
import { ThemeProvider, useTheme } from "next-themes";
import { HashRouter, Route, Routes } from "react-router";
import { invoke } from "@tauri-apps/api/core";
import { Toaster } from "@/components/ui/sonner";
import { Sidebar } from "@/components/layout/Sidebar";
import { AboutDialog } from "@/components/layout/AboutDialog";
import { UpdateDialog } from "@/components/layout/UpdateDialog";
import { OverviewPage } from "@/pages/Overview";
import { TargetDetailPage } from "@/pages/TargetDetail";
import { SystemPage } from "@/pages/System";
import { SettingsPage } from "@/pages/Settings";
import { EmailReportSettingsPage } from "@/pages/EmailReportSettings";
import { AlertsDataSettingsPage } from "@/pages/AlertsDataSettings";
import { LanguageProvider } from "@/lib/i18n/context";

/// The macOS vibrancy blur is a native window-level effect, not CSS — it
/// must be told the resolved theme separately or it keeps rendering with
/// whatever appearance the window started with, regardless of the in-app
/// theme toggle.
function NativeThemeSync() {
  const { theme } = useTheme();

  useEffect(() => {
    // Pass the user's selected mode, not the resolved value — when it's
    // "system", the native window must keep tracking OS appearance changes
    // itself rather than being pinned to whatever it resolved to right now.
    if (theme) {
      invoke("set_native_theme", { theme }).catch(() => {});
    }
  }, [theme]);

  return null;
}

function App() {
  return (
    <ThemeProvider attribute="class" defaultTheme="system" enableSystem>
      <NativeThemeSync />
      <LanguageProvider>
        <UpdateDialog />
        <AboutDialog />
        <HashRouter>
          <div className="flex h-screen text-foreground">
            <div data-tauri-drag-region className="fixed inset-x-0 top-0 z-30 h-11" />
            <Sidebar />
            <main className="flex flex-1 flex-col overflow-hidden">
              <Routes>
                <Route path="/" element={<OverviewPage />} />
                <Route path="/targets/:id" element={<TargetDetailPage />} />
                <Route path="/system" element={<SystemPage />} />
                <Route path="/settings" element={<SettingsPage />} />
                <Route path="/settings/email-report" element={<EmailReportSettingsPage />} />
                <Route path="/settings/alerts-data" element={<AlertsDataSettingsPage />} />
              </Routes>
            </main>
            <Toaster />
          </div>
        </HashRouter>
      </LanguageProvider>
    </ThemeProvider>
  );
}

export default App;
