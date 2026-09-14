import { cp, mkdir } from "node:fs/promises";
import { products } from "../src/catalog.ts";
import { GITHUB_REPO } from "../src/shared/github.ts";
import { writeGithubStars } from "./github-stars.mjs";

const publicDir = new URL("../public/", import.meta.url);
const root = new URL("../../../", import.meta.url);
await mkdir(publicDir, { recursive: true });
await cp(new URL("design/assets/openapps-hq/", root), new URL("brand/openapps-hq/", publicDir), {
  recursive: true,
});
for (const product of products) {
  await cp(new URL(`${product.brandSource}/`, root), new URL(`brand/${product.id}/`, publicDir), {
    recursive: true,
  });
  for (const asset of product.assets) {
    await cp(
      new URL(`${asset.source}/`, root),
      new URL(`${product.route.slice(1)}/${asset.destination}/`, publicDir),
      { recursive: true },
    );
  }
}
await writeGithubStars(GITHUB_REPO, new URL("data/github.json", publicDir));
