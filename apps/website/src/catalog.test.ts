import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vite-plus/test";
import { findPage, pages, productPages, products } from "./catalog";
import { preparePages } from "../scripts/pages";

test("each product owns its routes and adding another product cannot shadow OpenKlack", () => {
  const next = { ...products[0]!, id: "another-app", route: "/another_route", name: "Another app" };
  const combined = productPages([...products, next]);
  expect(combined.map((page) => page.path)).toEqual([
    "/openklack/",
    "/openklack/download/",
    "/openklack/thanks/",
    "/openreaction/",
    "/openreaction/download/",
    "/openreaction/thanks/",
    "/another_route/",
    "/another_route/download/",
    "/another_route/thanks/",
  ]);
  expect(combined[6]?.productId).toBe("another-app");
  expect(findPage("/openklack/download/")?.productId).toBe("openklack");
  expect(combined[6]?.module).toBe("./apps/another-app/pages/Home.tsx");
  expect(findPage("/openklack/thanks/trial/")).toBeUndefined();
  expect(findPage("/openreaction/")?.module).toBe("./apps/openreaction/pages/Home.tsx");
  for (const path of ["/openklack", "/openklack/", "/openklack/index.html"])
    expect(findPage(path)?.entry).toBe("Home");
  expect(findPage("/openklack/download/")?.entry).toBe("Download");
  expect(findPage("/openklack/not-a-page")).toBeUndefined();
  expect(findPage("/unknown")).toBeUndefined();
  expect(() => productPages([...products, { ...next, route: "/openklack" }])).toThrow(
    "Duplicate product route",
  );
  expect(() => productPages([{ ...next, route: "/../escape" }])).toThrow("Invalid product");
});

test("catalog routes emit separate static HTML entries with product metadata", () => {
  const root = mkdtempSync(join(tmpdir(), "openapps-pages-"));
  try {
    writeFileSync(
      join(root, "index.html"),
      readFileSync(new URL("../index.html", import.meta.url)),
    );
    for (const page of pages) {
      expect(existsSync(new URL(page.module, import.meta.url))).toBe(true);
      const module = join(root, "src", page.module);
      mkdirSync(join(module, ".."), { recursive: true });
      writeFileSync(module, "");
      if (page.template) {
        const template = join(root, page.template);
        mkdirSync(join(template, ".."), { recursive: true });
        writeFileSync(template, readFileSync(new URL(`../${page.template}`, import.meta.url)));
      }
    }
    const inputs = preparePages(root);
    expect(readFileSync(join(root, "thanks/index.html"), "utf8")).toContain(
      'name="robots" content="noindex"',
    );
    expect(readFileSync(join(root, "openreaction/thanks/index.html"), "utf8")).toContain(
      'name="robots" content="noindex"',
    );
    expect(readFileSync(join(root, "openreaction/index.html"), "utf8")).not.toContain("noindex");
    for (const file of ["thanks", "openreaction/thanks", "openklack/thanks"]) {
      const html = readFileSync(join(root, `${file}/index.html`), "utf8");
      const head = html.slice(html.indexOf("<head>") + 6);
      // The referrer policy and capture script must precede every other head tag.
      expect(
        head.trimStart().startsWith('<meta name="referrer" content="no-referrer" />'),
        file,
      ).toBe(true);
      expect(head.indexOf("__openappsCheckout"), file).toBeLessThan(head.indexOf("<meta charset"));
      expect(head.indexOf("<script>"), file).toBeLessThan(head.indexOf("<link"));
    }
    expect(readFileSync(join(root, "openreaction/index.html"), "utf8")).not.toContain(
      "__openappsCheckout",
    );
    expect(inputs).toContain(join(root, "openklack/download/index.html"));
    expect(readFileSync(join(root, "openklack/download/index.html"), "utf8")).toContain(
      "Install · OpenKlack",
    );
    expect(readFileSync(join(root, "openklack/download/index.html"), "utf8")).toContain(
      'content="Install OpenKlack with Homebrew,',
    );
    expect(readFileSync(join(root, "openklack/index.html"), "utf8")).toContain(
      'property="og:site_name" content="OpenKlack"',
    );
    const home = readFileSync(join(root, "index.html"), "utf8");
    expect(home).toContain("OpenApps HQ · Small apps. Room for personality.");
    expect(existsSync(join(root, "home/index.html"))).toBe(false);
    expect(existsSync(join(root, "download/index.html"))).toBe(false);
    const reaction = readFileSync(join(root, "openreaction/index.html"), "utf8");
    expect(reaction).toContain('content="/openreaction/og.png"');
    expect(reaction).toContain("/src/main.tsx");
    expect(inputs).toHaveLength(pages.length + 1);
  } finally {
    rmSync(root, { recursive: true });
  }
});
