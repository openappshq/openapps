import { defineConfig } from "vite-plus";

// https://vite.dev/config/
export default defineConfig({
  fmt: { ignorePatterns: ["apps/website/public/draco/**", "packages/soundpacks/catalog.json"] },
  lint: {
    ignorePatterns: ["apps/website/public/draco/**"],
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
