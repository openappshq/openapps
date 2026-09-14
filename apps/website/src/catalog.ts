export type Product = {
  id: string;
  route: string;
  name: string;
  description: string;
  platform: string;
  status: "In development" | "Available";
  icon: string;
  accent: "cobalt" | "orchid";
  brandSource: string;
  assets: { source: string; destination: string }[];
  pages: { path: string; entry: string; title: string; description: string; template?: string }[];
};

export const products: Product[] = [
  {
    id: "openklack",
    route: "/OpenKlack",
    name: "OpenKlack",
    description: "Mechanical keyboard sounds. For the keyboard you already own.",
    platform: "macOS",
    status: "In development",
    icon: "/brand/openklack/app-icon.svg",
    accent: "cobalt",
    brandSource: "design/assets/openklack",
    assets: [
      { source: "packages/openklack-ui/assets", destination: "" },
      { source: "packages/soundpacks/sounds", destination: "sounds" },
    ],
    pages: [
      {
        path: "",
        entry: "Home",
        title: "OpenKlack · Your keyboard, with character",
        description:
          "Try 18 recorded keyboard sounds and meet OpenKlack, the free, open-source Mac utility.",
      },
      {
        path: "download",
        entry: "Download",
        title: "Download for Mac · OpenKlack",
        description:
          "Get OpenKlack for Mac. Installation steps, release information, and ways to support the app.",
      },
    ],
  },
  {
    id: "openreaction",
    route: "/openreaction",
    name: "OpenReaction",
    description: "Type :tada: in any text field on your Mac. Get 🎉.",
    platform: "macOS",
    status: "In development",
    icon: "/brand/openreaction/app-icon.svg",
    accent: "orchid",
    brandSource: "apps/openreaction/design/assets",
    assets: [
      { source: "apps/openreaction/Sources/OpenReactionCore/Resources", destination: "data" },
    ],
    pages: [
      {
        path: "",
        entry: "Home",
        title: "OpenReaction · Emoji shortcodes, everywhere on your Mac",
        description:
          "Type :tada in any text field on your Mac and get 🎉. OpenReaction is a free, open-source menu-bar app for emoji shortcodes everywhere. No account, no telemetry.",
        template: "src/apps/openreaction/template.html",
      },
    ],
  },
];

export function productPages(catalog = products) {
  const paths = new Set<string>();
  const ids = new Set<string>();
  return catalog.flatMap((product) => {
    if (!/^[a-z][a-z0-9-]*$/.test(product.id) || !/^\/[A-Za-z][A-Za-z0-9_-]*$/.test(product.route))
      throw new Error(`Invalid product id or route: ${product.id}`);
    if (ids.has(product.id)) throw new Error(`Duplicate product id: ${product.id}`);
    if (
      ["/assets", "/brand", "/src", "/public", "/scripts", "/node_modules"].includes(
        product.route.toLowerCase(),
      )
    )
      throw new Error(`Reserved product route: ${product.route}`);
    ids.add(product.id);
    if (!product.pages.some((page) => page.path === ""))
      throw new Error(`Missing home page: ${product.name}`);
    return product.pages.map((page) => {
      if (
        !/^[A-Za-z][A-Za-z0-9_-]*$/.test(page.entry) ||
        (page.path && !/^[a-z][a-z0-9-]*$/.test(page.path))
      )
        throw new Error(`Invalid page in ${product.name}: ${page.path}`);
      const path = `${product.route}/${page.path ? `${page.path}/` : ""}`;
      if (paths.has(path.toLowerCase())) throw new Error(`Duplicate product route: ${path}`);
      paths.add(path.toLowerCase());
      return {
        ...page,
        path,
        icon: product.icon,
        siteName: product.name,
        module: `./apps/${product.id}/pages/${page.entry}.tsx`,
      };
    });
  });
}

export const pages = productPages();

export function findPage(pathname: string) {
  const path = pathname
    .replace(/\/index\.html$/, "")
    .replace(/\/+$/, "")
    .toLowerCase();
  return pages.find((page) => page.path.slice(0, -1).toLowerCase() === path);
}
