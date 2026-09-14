import { DMG, dmgArtworkBody, DMG_COLORS } from "./dmgArtwork";
import "./install-animation.css";

const CHROME = 52;
const ICON = DMG.iconSize / 2;

/**
 * The install, shown rather than listed: the disk image that will open on the
 * visitor's Mac, with the icon dragged out and into Applications.
 *
 * The window is not a decorative frame - it is the same artwork and the same
 * icon positions the bundler is given, so the page is a rehearsal of the screen
 * rather than an illustration of one.
 *
 * Applications is drawn in two halves with the icon between them, so the icon
 * passes behind the front panel. That z-order is the whole illusion.
 */
export default function InstallAnimation({ app, name }: { app: string; name: string }) {
  const colors = DMG_COLORS[app] ?? DMG_COLORS.openklack!;
  const folderY = CHROME + DMG.applications.y;

  return (
    <svg
      className="install-scene"
      viewBox={`0 0 ${DMG.width} ${CHROME + DMG.height}`}
      role="img"
      aria-label={`The ${name} disk image, with its icon being dragged into the Applications folder.`}
    >
      <defs>
        <clipPath id={`ia-clip-${app}`}>
          <rect width={DMG.width} height={CHROME + DMG.height} rx="14" />
        </clipPath>
        <filter id="ia-soft" x="-70%" y="-70%" width="240%" height="240%">
          <feGaussianBlur stdDeviation="9" />
        </filter>
        <linearGradient id="ia-folder-back" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#6fbcf0" />
          <stop offset="1" stopColor="#3f93d8" />
        </linearGradient>
        <linearGradient id="ia-folder-front" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#a5d6fa" />
          <stop offset="1" stopColor="#5aa8e6" />
        </linearGradient>
      </defs>

      <g clipPath={`url(#ia-clip-${app})`}>
        <rect width={DMG.width} height={CHROME + DMG.height} fill="#e9e9ec" />
        {/* A real Finder window keeps the one piece of chrome that says so. */}
        <circle cx="26" cy={CHROME / 2} r="6" fill="#ff5f57" />
        <circle cx="46" cy={CHROME / 2} r="6" fill="#febc2e" />
        <circle cx="66" cy={CHROME / 2} r="6" fill="#28c840" />

        {/* The artwork, from the same module the installer is built from. The
            markup is authored in this repo and never comes from user input. */}
        <g
          transform={`translate(0 ${CHROME})`}
          dangerouslySetInnerHTML={{ __html: dmgArtworkBody(colors) }}
        />

        <g className="ia-folder" transform={`translate(${DMG.applications.x} ${folderY})`}>
          <ellipse className="ia-folder-shadow" cy="58" rx="60" ry="12" filter="url(#ia-soft)" />
          <path
            fill="url(#ia-folder-back)"
            d="M -64 -34 a 12 12 0 0 1 12 -12 h 34 a 7 7 0 0 1 5 2 l 7 7 a 7 7 0 0 0 5 2 h 55 a 12 12 0 0 1 12 12 v 42 h -130 z"
          />
          <g className="ia-folder-front">
            <path
              fill="url(#ia-folder-front)"
              d="M -68 -2 a 8 8 0 0 1 8 -8 h 120 a 8 8 0 0 1 8 8 v 30 a 13 13 0 0 1 -13 13 h -110 a 13 13 0 0 1 -13 -13 z"
            />
            <g
              fill="none"
              stroke="#ffffff"
              strokeOpacity="0.72"
              strokeWidth="4.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <path d="M -13 22 L 0 -1 L 13 22" />
              <path d="M -7 12 H 7" />
            </g>
          </g>
        </g>

        {/* The icon. The wrapper puts it in its slot; the animated group only
            ever applies deltas from there, so every transform is relative and
            none of them depends on where the canvas happens to be centred. */}
        <g transform={`translate(${DMG.app.x} ${CHROME + DMG.app.y})`}>
          <ellipse className="ia-shadow" cy="58" rx="46" ry="11" filter="url(#ia-soft)" />
          <g className="ia-drag">
            <image href={`/brand/${app}/app-icon.svg`} x={-ICON} y={-ICON} width={DMG.iconSize} height={DMG.iconSize} />
          </g>
        </g>
      </g>
      <rect
        width={DMG.width - 1}
        height={CHROME + DMG.height - 1}
        x="0.5"
        y="0.5"
        rx="13.5"
        fill="none"
        stroke="#000000"
        strokeOpacity="0.18"
      />
    </svg>
  );
}
