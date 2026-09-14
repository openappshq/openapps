import { createRoot } from "react-dom/client";
import App from "./App";
import { AppMotion } from "@openapps/ui/motion";
import "@fontsource-variable/bricolage-grotesque";
import "@fontsource-variable/instrument-sans";
import "@fontsource/ibm-plex-mono/400.css";
import "./styles.css";

createRoot(document.getElementById("root")!).render(
  <AppMotion>
    <App />
  </AppMotion>,
);
