import { lazy, StrictMode, Suspense, type ComponentType } from "react";
import { createRoot } from "react-dom/client";
import { Link, Spinner } from "@heroui/react";
import "@fontsource-variable/bricolage-grotesque";
import "@fontsource-variable/instrument-sans";
import "@fontsource/ibm-plex-mono/400.css";
import "./styles.css";
import { AppMotion } from "@openapps/ui/motion";
import { findPage } from "./catalog";

const modules = import.meta.glob<{ default: ComponentType }>("./apps/*/pages/*.tsx");
const page = findPage(location.pathname);
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
