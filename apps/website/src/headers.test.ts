import { expect, test } from "vite-plus/test";
import { siteHeaders } from "../headers";
import { pages } from "./catalog";

const rules = (text: string) =>
  new Map(
    text
      .trim()
      .split("\n\n")
      .map((block) => {
        const [path, ...headers] = block.split("\n");
        return [path!, headers.map((header) => header.trim())];
      }),
  );

test("every checkout return page is uncached, unindexed and sends no referrer", () => {
  const headers = rules(siteHeaders());
  const returns = pages.filter((page) => page.checkoutReturn).map((page) => page.path);
  expect(returns).toEqual(
    expect.arrayContaining(["/openklack/thanks/", "/openreaction/thanks/", "/thanks/"]),
  );
  for (const path of returns) {
    expect(headers.get(path), path).toEqual([
      "! Referrer-Policy",
      "Referrer-Policy: no-referrer",
      "X-Robots-Tag: noindex",
      "Cache-Control: no-store",
    ]);
  }
  expect(headers.has("/openklack/")).toBe(false);
});

test("install scripts are served as shell and revalidated by every client", () => {
  const headers = rules(siteHeaders());
  expect(headers.get("/install/*")).toEqual([
    "Content-Type: text/x-shellscript; charset=utf-8",
    "Cache-Control: public, max-age=0, s-maxage=300, must-revalidate",
    "X-Robots-Tag: noindex",
  ]);
});

test("every response gets baseline security headers and hashed assets cache forever", () => {
  const headers = rules(siteHeaders());
  expect(headers.get("/*")).toEqual(
    expect.arrayContaining([
      "X-Content-Type-Options: nosniff",
      "X-Frame-Options: DENY",
      "Strict-Transport-Security: max-age=63072000",
    ]),
  );
  expect(headers.get("/assets/*")).toEqual(["Cache-Control: public, max-age=31536000, immutable"]);
  expect(headers.get("/updates/*")).toEqual(["Cache-Control: public, max-age=300"]);
  // Cloudflare's limits: 100 rules, 2,000 characters per line.
  expect(headers.size).toBeLessThanOrEqual(100);
  for (const line of siteHeaders().split("\n")) expect(line.length).toBeLessThan(2000);
});
