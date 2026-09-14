import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, lazyPlugins } from "vite-plus";
import { resolve } from "node:path";

export default defineConfig({
  server: { host: "127.0.0.1", port: 5173, strictPort: true },
  plugins: lazyPlugins(() => [react(), tailwindcss()]),
  build: {
    outDir: "../../dist",
    emptyOutDir: true,
    rolldownOptions: {
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        download: resolve(import.meta.dirname, "download/index.html"),
      },
    },
  },
});
