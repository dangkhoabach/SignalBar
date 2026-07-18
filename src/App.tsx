import { ThemeProvider } from "next-themes";
import { HashRouter, Route, Routes } from "react-router";
import { Toaster } from "@/components/ui/sonner";
import { Sidebar } from "@/components/layout/Sidebar";
import { OverviewPage } from "@/pages/Overview";
import { TargetDetailPage } from "@/pages/TargetDetail";
import { SettingsPage } from "@/pages/Settings";
import { LanguageProvider } from "@/lib/i18n/context";

function App() {
  return (
    <ThemeProvider attribute="class" defaultTheme="system" enableSystem>
      <LanguageProvider>
        <HashRouter>
          <div className="flex h-screen text-foreground">
            <Sidebar />
            <main className="flex flex-1 flex-col overflow-hidden">
              <Routes>
                <Route path="/" element={<OverviewPage />} />
                <Route path="/targets/:id" element={<TargetDetailPage />} />
                <Route path="/settings" element={<SettingsPage />} />
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
