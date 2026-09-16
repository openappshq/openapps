export type Product = {
  id: string;
  route: string;
  name: string;
  description: string;
  platform: string;
  /** What this app costs, once. Apps are priced individually; "Free" for a free one. */
  price: string;
  /**
   * Free and open source: no license, no trial and no Buy button. Installed
   * with the one-line install script (or `brew install --cask
   * openappshq/tap/<id>`), so it has no download page and no checkout return
   * page either.
   */
  free?: boolean;
  /**
   * The macOS permissions the app asks for on first launch, named as System
   * Settings names them (e.g. "Input Monitoring"). Left out for an app that
   * asks for nothing. The install guide and the setup copy read this.
   */
  permissions?: readonly string[];
  /**
   * Where the app shows up once it opens, for the install guide's last step:
   * "It <arrival>." Left out for an app that appears in the menu bar.
   */
  arrival?: string;
  icon: string;
  accent: "cobalt" | "orchid" | "green" | "tangerine" | "coral";
  /** Whether `/brand/<id>/wordmark-{ink,paper}.svg` exist; otherwise the name is set in type. */
  wordmark?: boolean;
  brandSource: string;
  assets: { source: string; destination: string }[];
  pages: {
    path: string;
    entry: string;
    title: string;
    description: string;
    template?: string;
    /** Keep search engines away, e.g. from the checkout return page. */
    noindex?: boolean;
    /** Checkout returns here: the head captures and scrubs the query before anything loads. */
    checkoutReturn?: boolean;
  }[];
};

export const products: Product[] = [
  {
    id: "openklack",
    route: "/openklack",
    name: "OpenKlack",
    description: "Mechanical keyboard sounds. For the keyboard you already own.",
    platform: "macOS",
    price: "$5",
    permissions: ["Input Monitoring"],
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
          "Try 18 recorded keyboard sounds and meet OpenKlack, the open-source Mac utility.",
      },
      {
        path: "download",
        entry: "Download",
        title: "Install · OpenKlack",
        description: "Install OpenKlack with one Terminal line, and the one step to set it up.",
      },
      {
        path: "thanks",
        entry: "Thanks",
        title: "Thank you · OpenKlack",
        description: "Your OpenKlack license key and how to activate it.",
        noindex: true,
        checkoutReturn: true,
      },
    ],
  },
  {
    id: "openreaction",
    route: "/openreaction",
    name: "OpenReaction",
    description: "Type :tada: in any text field on your Mac. Get 🎉.",
    platform: "macOS",
    price: "$5",
    permissions: ["Accessibility", "Input Monitoring"],
    icon: "/brand/openreaction/app-icon.svg",
    accent: "orchid",
    wordmark: false,
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
          "Type :tada in any text field on your Mac and get 🎉. OpenReaction is an open-source menu-bar app for emoji shortcodes everywhere. No account, no telemetry.",
        template: "src/apps/openreaction/template.html",
      },
      {
        path: "download",
        entry: "Download",
        title: "Install · OpenReaction",
        description: "Install OpenReaction with one Terminal line, and the one step to set it up.",
        template: "src/apps/openreaction/template.html",
      },
      {
        path: "thanks",
        entry: "Thanks",
        title: "Thank you · OpenReaction",
        description: "Your OpenReaction license key and how to activate it.",
        template: "src/apps/openreaction/template.html",
        noindex: true,
        checkoutReturn: true,
      },
    ],
  },
  {
    id: "hertz",
    route: "/hertz",
    name: "Hertz",
    description: "Native macOS menu-bar system monitor.",
    platform: "macOS",
    price: "$5",
    icon: "/brand/hertz/app-icon.svg",
    accent: "green",
    wordmark: false,
    brandSource: "apps/hertz/design/assets",
    assets: [],
    pages: [
      {
        path: "",
        entry: "Home",
        title: "Hertz · Native macOS menu-bar system monitor",
        description:
          "CPU, memory, disk, network, battery and thermals in your menu bar, read straight from the kernel. Hertz is an open-source Mac app. No permissions, no telemetry.",
        template: "src/apps/hertz/template.html",
      },
      {
        path: "download",
        entry: "Download",
        title: "Install · Hertz",
        description: "Install Hertz with Homebrew. Nothing to grant, nothing to set up.",
        template: "src/apps/hertz/template.html",
      },
      {
        path: "thanks",
        entry: "Thanks",
        title: "Thank you · Hertz",
        description: "Your Hertz license key and how to activate it.",
        template: "src/apps/hertz/template.html",
        noindex: true,
        checkoutReturn: true,
      },
    ],
  },
  {
    id: "macpaper",
    route: "/macpaper",
    name: "macPaper",
    description: "Wallpapers your Mac makes itself, from the notch.",
    platform: "macOS",
    price: "$5",
    permissions: [],
    icon: "/brand/macpaper/app-icon.svg",
    accent: "tangerine",
    wordmark: false,
    brandSource: "apps/macpaper/design/assets",
    assets: [],
    pages: [
      {
        path: "",
        entry: "Home",
        title: "macPaper · Wallpapers your Mac makes itself",
        description:
          "Gradients, meshes, patterns, dither and pixel art, light-and-dark and time-of-day pairs, made on your Mac at native pixels and set on every display from a panel that drops out of the notch. macPaper is an open-source Mac app. No permissions, no telemetry.",
        template: "src/apps/macpaper/template.html",
      },
      {
        path: "download",
        entry: "Download",
        title: "Install · macPaper",
        description: "Install macPaper with one Terminal line. Nothing to grant, nothing to set up.",
        template: "src/apps/macpaper/template.html",
      },
      {
        path: "thanks",
        entry: "Thanks",
        title: "Thank you · macPaper",
        description: "Your macPaper license key and how to activate it.",
        template: "src/apps/macpaper/template.html",
        noindex: true,
        checkoutReturn: true,
      },
    ],
  },
  {
    id: "opennotes",
    route: "/opennotes",
    name: "OpenNotes",
    description: "Sticky notes on the edge of your screen. Plain Markdown files underneath.",
    platform: "macOS",
    price: "$5",
    permissions: [],
    arrival: "shows up as a pill on the edge of your screen",
    icon: "/brand/opennotes/app-icon.svg",
    accent: "coral",
    wordmark: false,
    brandSource: "apps/opennotes/design/assets",
    assets: [],
    pages: [
      {
        path: "",
        entry: "Home",
        title: "OpenNotes · Sticky notes on the edge of your screen",
        description:
          "A deck of sticky notes docked to the edge of your screen: a thin pill at rest, a fan when you reach for it, one note out to write. Visible over full-screen apps, captured from anywhere with a hotkey, kept as plain Markdown files in a folder you choose. OpenNotes is an open-source Mac app. No permissions, no telemetry.",
        template: "src/apps/opennotes/template.html",
      },
      {
        path: "download",
        entry: "Download",
        title: "Install · OpenNotes",
        description: "Install OpenNotes with one Terminal line. Nothing to grant, nothing to set up.",
        template: "src/apps/opennotes/template.html",
      },
      {
        path: "thanks",
        entry: "Thanks",
        title: "Thank you · OpenNotes",
        description: "Your OpenNotes license key and how to activate it.",
        template: "src/apps/opennotes/template.html",
        noindex: true,
        checkoutReturn: true,
      },
    ],
  },
];

/** The apps that are sold: everything licensing, checkout and download pages apply to. */
export const paidProducts = products.filter((product) => !product.free);

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
        (page.path && !/^[a-z][a-z0-9-]*(\/[a-z][a-z0-9-]*)?$/.test(page.path))
      )
        throw new Error(`Invalid page in ${product.name}: ${page.path}`);
      const path = `${product.route}/${page.path ? `${page.path}/` : ""}`;
      if (paths.has(path.toLowerCase())) throw new Error(`Duplicate product route: ${path}`);
      paths.add(path.toLowerCase());
      return {
        ...page,
        productId: product.id,
        path,
        icon: product.icon,
        siteName: product.name,
        module: `./apps/${product.id}/pages/${page.entry}.tsx`,
      };
    });
  });
}

export interface SitePage {
  productId?: string;
  path: string;
  entry: string;
  title: string;
  description: string;
  icon: string;
  siteName: string;
  module: string;
  template?: string;
  noindex?: boolean;
  checkoutReturn?: boolean;
}

/** Pages that belong to the site rather than to one product. */
export const sitePages: SitePage[] = [
  {
    path: "/thanks/",
    entry: "Thanks",
    title: "Thank you · OpenApps",
    description: "Your OpenApps license keys and how to activate each app.",
    icon: "/brand/openapps-hq/app-icon.svg",
    siteName: "OpenApps HQ",
    module: "./site/Thanks.tsx",
    noindex: true,
    checkoutReturn: true,
  },
];

export const pages: SitePage[] = [...productPages(), ...sitePages];

export function findPage(pathname: string) {
  const path = pathname
    .replace(/\/index\.html$/, "")
    .replace(/\/+$/, "")
    .toLowerCase();
  return pages.find((page) => page.path.slice(0, -1).toLowerCase() === path);
}
