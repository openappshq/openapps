import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, lazyPlugins } from "vite-plus";
import { resolve } from "node:path";
import { unknownPageRedirects } from "./redirects.ts";

export default defineConfig({
  server: { host: "127.0.0.1", port: 5173, strictPort: true },
  // Several standalone pages; unknown ones redirect to /home/ (see public/404.html for hosting).
  appType: "mpa",
  plugins: lazyPlugins(() => [react(), tailwindcss(), unknownPageRedirects()]),
  build: {
    outDir: "../../dist",
    emptyOutDir: true,
    // Each page is its own entry so static hosting serves every page without a router.
    rolldownOptions: {
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        download: resolve(import.meta.dirname, "download/index.html"),
        openreaction: resolve(import.meta.dirname, "openreaction/index.html"),
        home: resolve(import.meta.dirname, "home/index.html"),
      },
    },
  },
});
