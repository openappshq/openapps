import { createRoot } from "react-dom/client";
import App from "./App";
import { AppMotion } from "@openklack/ui/motion";
import "@fontsource-variable/geist";
import "@fontsource-variable/geist-mono";
import "./styles.css";

createRoot(document.getElementById("root")!).render(
  <AppMotion>
    <App />
  </AppMotion>,
);
