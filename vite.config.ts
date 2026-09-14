import { defineConfig } from "vite-plus";

// https://vite.dev/config/
export default defineConfig({
  fmt: { ignorePatterns: ["packages/soundpacks/catalog.json"] },
  // The site Worker's tests run in workerd through its own Vitest (`pnpm site:test`).
  test: { exclude: ["**/node_modules/**", "**/dist/**", "apps/site-worker/**"] },
  lint: {
    ignorePatterns: ["**/assets/draco/**", "**/public/draco/**", "**/.wrangler/**"],
    plugins: ["react", "typescript", "oxc"],
    rules: {
      "react/rules-of-hooks": "error",
      "react/only-export-components": [
        "warn",
        {
          allowConstantExport: true,
        },
      ],
      "vite-plus/prefer-vite-plus-imports": "error",
    },
    options: {
      typeAware: true,
      typeCheck: true,
    },
    jsPlugins: [
      {
        name: "vite-plus",
        specifier: "vite-plus/oxlint-plugin",
      },
    ],
  },
});
