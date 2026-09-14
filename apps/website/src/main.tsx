import { lazy, StrictMode, Suspense, type ComponentType } from "react";
import { createRoot } from "react-dom/client";
import { Link, Spinner } from "@heroui/react";
import "@fontsource-variable/bricolage-grotesque";
import "@fontsource-variable/instrument-sans";
import "@fontsource/ibm-plex-mono/400.css";
import "./styles.css";
import { AppMotion } from "@openapps/ui/motion";
import { withoutThemeTransitions } from "@openapps/ui/theme";
import { findPage } from "./catalog";

const modules = import.meta.glob<{ default: ComponentType }>([
  "./apps/*/pages/*.tsx",
  "./site/*.tsx",
]);
const page = findPage(location.pathname);
document.documentElement.dataset.product = page?.productId ?? "openapps-hq";
const systemTheme = matchMedia("(prefers-color-scheme: dark)");
const applyTheme = () => {
  document.documentElement.dataset.theme = systemTheme.matches ? "dark" : "light";
};
applyTheme();
const onThemeChange = () => withoutThemeTransitions(applyTheme);
systemTheme.addEventListener("change", onThemeChange);
if (import.meta.hot)
  import.meta.hot.dispose(() => systemTheme.removeEventListener("change", onThemeChange));
const isHome = location.pathname === "/" || location.pathname === "/index.html";
const Page = page ? lazy(modules[page.module]!) : isHome ? lazy(() => import("./home/App")) : null;

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AppMotion>
      <Suspense
        fallback={
          <main className="route-status">
            <Spinner aria-label="Loading app" />
          </main>
        }
      >
        {Page ? (
          <Page />
        ) : (
          <main className="route-status">
            <h1>That app isn’t here.</h1>
            <Link href="/">Explore OpenApps</Link>
          </main>
        )}
      </Suspense>
    </AppMotion>
  </StrictMode>,
);
