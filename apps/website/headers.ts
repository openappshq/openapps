import type { Plugin } from "vite";
import { pages, type SitePage } from "./src/catalog.ts";

/**
 * Response headers for static hosting, in the `_headers` format Cloudflare
 * Workers static assets read. Every page gets baseline security headers;
 * hashed build assets are cached for good; checkout return pages are never
 * cached, indexed, or allowed to send a referrer.
 */
export function siteHeaders(sitePages: SitePage[] = pages): string {
  const rules = [
    [
      "/*",
      "Strict-Transport-Security: max-age=63072000",
      "X-Content-Type-Options: nosniff",
      "Referrer-Policy: strict-origin-when-cross-origin",
      "X-Frame-Options: DENY",
      "Content-Security-Policy: frame-ancestors 'none'; base-uri 'self'; object-src 'none'",
      "Cross-Origin-Opener-Policy: same-origin",
      "Permissions-Policy: camera=(), geolocation=(), microphone=(), payment=(), usb=()",
    ],
    ["/assets/*", "Cache-Control: public, max-age=31536000, immutable"],
    ...sitePages
      .filter((page) => page.noindex)
      .map((page) => [
        page.path,
        "! Referrer-Policy",
        "Referrer-Policy: no-referrer",
        "X-Robots-Tag: noindex",
        "Cache-Control: no-store",
      ]),
  ];
  return `${rules.map(([path, ...headers]) => [path, ...headers.map((header) => `  ${header}`)].join("\n")).join("\n\n")}\n`;
}

/** Emits `_headers` next to the built pages. */
export function staticHostHeaders(): Plugin {
  return {
    name: "openapps:static-host-headers",
    apply: "build",
    generateBundle() {
      this.emitFile({ type: "asset", fileName: "_headers", source: siteHeaders() });
    },
  };
}
