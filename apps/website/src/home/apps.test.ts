import { existsSync } from "node:fs";
import { describe, expect, it } from "vite-plus/test";
import { apps, routes } from "./apps";

describe("apps", () => {
  it("have unique slugs and names", () => {
    expect(new Set(apps.map((app) => app.slug)).size).toBe(apps.length);
    expect(new Set(apps.map((app) => app.name)).size).toBe(apps.length);
  });

  it("link to pages this site serves", () => {
    for (const app of apps) expect(routes, app.slug).toContain(app.href);
  });

  it("have a page entry for every route", () => {
    for (const route of routes) {
      const entry = route === "/" ? "index.html" : `${route.slice(1)}index.html`;
      expect(existsSync(new URL(`../../${entry}`, import.meta.url)), route).toBe(true);
    }
  });

  it("use prepared brand icons", () => {
    for (const app of apps) {
      expect(app.icon, app.slug).toMatch(/^\/brand\/[a-z-]+\/app-icon\.svg$/);
      expect(app.tagline.length, app.slug).toBeLessThanOrEqual(80);
    }
  });
});
