import { ThemeProvider } from "next-themes";
import { Toaster } from "@/components/ui/sonner";
import { Sidebar } from "@/components/layout/Sidebar";
import { OverviewPage } from "@/pages/Overview";
import { LanguageProvider } from "@/lib/i18n/context";

function App() {
  return (
    <ThemeProvider attribute="class" defaultTheme="system" enableSystem>
      <LanguageProvider>
        <div className="flex h-screen text-foreground">
          <Sidebar activeItem="overview" />
          <main className="flex flex-1 flex-col overflow-hidden">
            <OverviewPage />
          </main>
          <Toaster />
        </div>
      </LanguageProvider>
    </ThemeProvider>
  );
}

export default App;
