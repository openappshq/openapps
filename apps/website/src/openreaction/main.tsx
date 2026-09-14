import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@fontsource-variable/bricolage-grotesque";
import "@fontsource-variable/instrument-sans";
import "@fontsource/ibm-plex-mono/400.css";
import "@fontsource/ibm-plex-mono/500.css";
import "./styles.css";
import App from "./App";
import { AppMotion } from "@openklack/ui/motion";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AppMotion>
      <App />
    </AppMotion>
  </StrictMode>,
);
