/**
 * The disk image's background artwork, authored once and used twice: rasterised
 * into the installer by `scripts/build-dmg-backgrounds.mjs`, and drawn live on
 * each product's download page. The window someone sees on the site is the
 * window they get, so the geometry below is shared rather than eyeballed twice.
 *
 * The background stays light on purpose. Finder draws the two icon labels in
 * the system text colour and will not adapt them to the artwork, so a dark
 * field would leave "Applications" unreadable.
 *
 * Everything here is plain geometry - no text, no external images - because the
 * same markup has to rasterise outside a browser.
 */
export const DMG = {
  width: 660,
  height: 400,
  /** Icon centres, measured from the top-left of the window's content area. */
  app: { x: 180, y: 170 },
  applications: { x: 480, y: 170 },
  /** Finder draws icons at this size. */
  iconSize: 128,
} as const;

/** A product's field colours. */
export interface DmgColors {
  /** The product's own colour, used for the keys. */
  brand: string;
  /** The wash behind everything. */
  tint: string;
}

/**
 * A key from the product's own headline, tossed onto the background. These are
 * the site's signature object, so they carry the brand here the way Figma's
 * installer carries multiplayer cursors: personality as props, not as a field.
 */
function key(x: number, y: number, size: number, tilt: number, brand: string, alpha: number) {
  const r = size * 0.22;
  return `
    <g transform="translate(${x} ${y}) rotate(${tilt})" opacity="${alpha}">
      <rect x="${-size / 2}" y="${-size / 2}" width="${size}" height="${size}" rx="${r}"
        fill="${brand}" />
      <rect x="${-size / 2 + size * 0.1}" y="${-size / 2 + size * 0.1}"
        width="${size * 0.8}" height="${size * 0.55}" rx="${r * 0.6}"
        fill="#ffffff" fill-opacity="0.22" />
    </g>`;
}

/**
 * The artwork's contents, without an `<svg>` wrapper, so the same markup can be
 * dropped inside the larger scene on the website.
 */
export function dmgArtworkBody({ brand, tint }: DmgColors): string {
  const ink = "#141414";
  return `
    <rect width="${DMG.width}" height="${DMG.height}" fill="${tint}" />

    <!-- Keys scattered clear of both icons and of the labels Finder puts
         under them, so nothing the system draws lands on top of artwork. -->
    ${key(58, 64, 44, -14, brand, 0.5)}
    ${key(624, 62, 44, 11, brand, 0.42)}
    ${key(88, 336, 38, 9, brand, 0.36)}
    ${key(566, 330, 46, -8, brand, 0.46)}
    ${key(330, 66, 32, 17, brand, 0.28)}

    <!-- The one instruction, drawn by hand rather than set in a font. -->
    <g fill="none" stroke="${ink}" stroke-linecap="round" stroke-linejoin="round">
      <path d="M 266 182 C 300 160 356 156 392 168" stroke-width="4.5" stroke-opacity="0.82" />
      <path d="M 378 156 L 395 169 L 377 180" stroke-width="4.5" stroke-opacity="0.82" />
    </g>

    <!-- Three marks of delight beside Applications, borrowed from every good
         installer that ever shipped. -->
    <g stroke="${ink}" stroke-linecap="round" stroke-width="4" stroke-opacity="0.5">
      <path d="M 540 74 L 536 94" />
      <path d="M 564 82 L 555 99" />
      <path d="M 580 102 L 566 112" />
    </g>`;
}

/** The same artwork as a standalone file, for the bundler to rasterise. */
export function dmgArtworkSvg(colors: DmgColors): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${DMG.width}" height="${DMG.height}" viewBox="0 0 ${DMG.width} ${DMG.height}">${dmgArtworkBody(colors)}</svg>`;
}

/** Each product's colours, resolved from the design tokens. */
export const DMG_COLORS: Record<string, DmgColors> = {
  openklack: { brand: "#304bff", tint: "#edf0ff" },
  openreaction: { brand: "#f3a0dc", tint: "#fdf2fa" },
};
