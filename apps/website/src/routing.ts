import { routes } from "./home/apps.ts";

export type PathKind = "page" | "asset" | "unknown";

/** Where visitors land when they ask for a page this site does not have. */
export const FALLBACK_PAGE = "/home/";

/**
 * Sorts a request path into a known page, a static asset (anything with a
 * non-HTML extension, which must 404 normally so fetches and images behave),
 * or an unknown page that should redirect to the fallback.
 */
export function classifyPath(pathname: string): PathKind {
  const path = pathname.split(/[?#]/, 1)[0];
  const extension = /\.([a-z0-9]+)$/i.exec(path)?.[1]?.toLowerCase();
  if (extension && extension !== "html") return "asset";
  const page = path.replace(/index\.html$/, "").replace(/\/?$/, "/");
  return (routes as readonly string[]).includes(page) ? "page" : "unknown";
}
