import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource-variable/bricolage-grotesque";
import "@fontsource-variable/instrument-sans";
import "@fontsource/ibm-plex-mono/400.css";
import "./styles.css";
import App from "./App";
import DownloadPage from "./DownloadPage";
import { AppMotion } from "@openklack/ui/motion";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AppMotion>
      {["/download", "/download/", "/download/index.html"].includes(location.pathname) ? (
        <DownloadPage downloadUrl={import.meta.env.VITE_MAC_DOWNLOAD_URL} />
      ) : (
        <App />
      )}
    </AppMotion>
  </StrictMode>,
);
