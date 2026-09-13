import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, lazyPlugins } from "vite-plus";

export default defineConfig({
  server: { host: "127.0.0.1", port: 5173, strictPort: true },
  plugins: lazyPlugins(() => [react(), tailwindcss()]),
  build: { outDir: "../../dist", emptyOutDir: true },
});
