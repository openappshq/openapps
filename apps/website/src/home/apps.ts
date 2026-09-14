export type AppStatus = "In development" | "Available";

export interface AppEntry {
  slug: string;
  name: string;
  tagline: string;
  /** Path under the site root; must be one of `routes`. */
  href: string;
  /** Tile icon copied by scripts/prepare-assets.mjs. */
  icon: string;
  /** Brand colour behind the tile on hover, from the Tactile Studio palette. */
  accent: "cobalt" | "orchid";
  platform: "Mac";
  price: "Free & open source";
  status: AppStatus;
}

/** Pages this website serves, so app links can be checked. */
export const routes = ["/", "/openreaction/", "/home/"] as const;

export const apps: AppEntry[] = [
  {
    slug: "openklack",
    name: "OpenKlack",
    tagline: "Mechanical keyboard sounds for the keyboard you already own.",
    href: "/",
    icon: "/brand/openklack/app-icon.svg",
    accent: "cobalt",
    platform: "Mac",
    price: "Free & open source",
    status: "In development",
  },
  {
    slug: "openreaction",
    name: "OpenReaction",
    tagline: "Type :tada: in any text field on your Mac. Get 🎉.",
    href: "/openreaction/",
    icon: "/brand/openreaction/app-icon.svg",
    accent: "orchid",
    platform: "Mac",
    price: "Free & open source",
    status: "In development",
  },
];
