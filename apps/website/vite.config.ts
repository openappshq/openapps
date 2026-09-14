import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, lazyPlugins } from "vite-plus";
import { unknownPageRedirects } from "./redirects.ts";

export default defineConfig({
  server: { host: "127.0.0.1", port: 5173, strictPort: true },
  // Several standalone pages; unknown ones redirect to /home/ (see public/404.html for hosting).
  appType: "mpa",
  plugins: lazyPlugins(() => [react(), tailwindcss(), unknownPageRedirects()]),
  build: {
    outDir: "../../dist",
    emptyOutDir: true,
    // Each page is its own entry so static hosting serves /openreaction/ without a router.
    rollupOptions: {
      input: {
        openklack: new URL("./index.html", import.meta.url).pathname,
        openreaction: new URL("./openreaction/index.html", import.meta.url).pathname,
        home: new URL("./home/index.html", import.meta.url).pathname,
      },
    },
  },
});
