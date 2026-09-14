import { defineConfig } from "vite-plus";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
export default defineConfig({
  publicDir: new URL("../../packages/openklack-ui/assets/", import.meta.url).pathname,
  plugins: [react(), tailwindcss()],
  clearScreen: false,
  server: { watch: { ignored: ["**/src-tauri/**"] } },
  build: { target: "safari17" },
});
