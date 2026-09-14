import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, lazyPlugins } from "vite-plus";

export default defineConfig({
  server: { host: "127.0.0.1", port: 5173, strictPort: true },
  plugins: lazyPlugins(() => [react(), tailwindcss()]),
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
