import type { Connect, Plugin } from "vite";
import { classifyPath, FALLBACK_PAGE } from "./src/routing.ts";

/**
 * Sends unknown page navigations to the fallback page, the way `public/404.html`
 * does on static hosting. Asset requests fall through so a missing file still 404s.
 */
function redirectUnknownPages(): Connect.NextHandleFunction {
  return (req, res, next) => {
    const wantsHtml = req.headers.accept?.includes("text/html");
    const path = req.url ?? "/";
    if (req.method === "GET" && wantsHtml && classifyPath(path) === "unknown") {
      res.statusCode = 302;
      res.setHeader("Location", FALLBACK_PAGE);
      res.end();
      return;
    }
    next();
  };
}

export function unknownPageRedirects(): Plugin {
  return {
    name: "openapps:unknown-page-redirects",
    configureServer(server) {
      server.middlewares.use(redirectUnknownPages());
    },
    configurePreviewServer(server) {
      server.middlewares.use(redirectUnknownPages());
    },
  };
}
