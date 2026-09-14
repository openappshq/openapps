import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pages } from "../src/catalog.ts";

const escapeHtml = (value: string) =>
  value.replace(/[&<>"']/g, (character) => `&#${character.charCodeAt(0)};`);

export function preparePages(root: string) {
  const template = readFileSync(resolve(root, "index.html"), "utf8");
  const inputs = [resolve(root, "index.html")];
  for (const page of pages) {
    if (!existsSync(resolve(root, "src", page.module)))
      throw new Error(`Missing page: ${page.module}`);
    const file = resolve(root, `.${page.path}index.html`);
    const pageTemplate = page.template
      ? readFileSync(resolve(root, page.template), "utf8")
      : template;
    const html = pageTemplate
      .replace(/<title>.*?<\/title>/, `<title>${escapeHtml(page.title)}</title>`)
      .replace(
        /name="description"\s+content="[^"]*"/,
        `name="description" content="${escapeHtml(page.description)}"`,
      )
      .replace(
        /property="og:site_name"\s+content="[^"]*"/,
        `property="og:site_name" content="${escapeHtml(page.siteName)}"`,
      )
      .replace(
        /property="og:title"\s+content="[^"]*"/,
        `property="og:title" content="${escapeHtml(page.title)}"`,
      )
      .replace(
        /property="og:description"\s+content="[^"]*"/,
        `property="og:description" content="${escapeHtml(page.description)}"`,
      )
      .replace(/rel="icon"\s+href="[^"]*"/, `rel="icon" href="${escapeHtml(page.icon)}"`);
    mkdirSync(dirname(file), { recursive: true });
    if (!existsSync(file) || readFileSync(file, "utf8") !== html) writeFileSync(file, html);
    inputs.push(file);
  }
  return inputs;
}
