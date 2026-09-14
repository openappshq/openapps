import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, lazyPlugins } from "vite-plus";
import { preparePages } from "./scripts/pages.ts";
import { staticHostHeaders } from "./headers.ts";
import { unknownPageRedirects } from "./redirects.ts";

export default defineConfig({
  appType: "mpa",
  server: { host: "127.0.0.1", port: 5173, strictPort: true },
  plugins: lazyPlugins(() => [
    react(),
    tailwindcss(),
    unknownPageRedirects(),
    staticHostHeaders(),
  ]),
  build: {
    outDir: "../../dist",
    emptyOutDir: true,
    rolldownOptions: {
      input: preparePages(import.meta.dirname),
    },
  },
});
