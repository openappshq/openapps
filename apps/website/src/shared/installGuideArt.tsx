import type { ReactNode } from "react";

/**
 * The pictures beside each install step: a menu bar with the search field, a
 * Terminal window, the menu bar again with a new icon in it, a permission
 * prompt. Drawn here in SVG on the design tokens (install-guide.css colours
 * every part) so they follow the theme and show nothing of Apple's own UI.
 * Every scene is decorative: the step's text says everything the picture does.
 */

const W = 320;

/** The strip along the top of the screen, with a few quiet status glyphs at the right. */
function MenuBar({ children }: { children?: ReactNode }) {
  return (
    <g className="ig-menubar">
      <rect className="ig-bar" width={W} height="22" />
      <circle className="ig-glyph" cx="14" cy="11" r="4" />
      <rect className="ig-glyph" x="34" y="8" width="26" height="6" rx="3" />
      <rect className="ig-glyph" x="68" y="8" width="18" height="6" rx="3" />
      <rect className="ig-glyph" x="94" y="8" width="22" height="6" rx="3" />
      <g className="ig-status">
        <rect className="ig-glyph" x={W - 30} y="7" width="14" height="8" rx="2" />
        <rect className="ig-glyph" x={W - 52} y="8" width="10" height="6" rx="1.5" />
        <rect className="ig-glyph" x={W - 74} y="8" width="10" height="6" rx="3" />
      </g>
      {children}
    </g>
  );
}

/** The one piece of window chrome that says "a window": three dots and a title bar. */
function Window({
  y,
  height,
  dark = false,
  children,
}: {
  y: number;
  height: number;
  dark?: boolean;
  children?: ReactNode;
}) {
  return (
    <g transform={`translate(0 ${y})`}>
      <rect
        className={dark ? "ig-window ig-window-dark" : "ig-window"}
        x="0.5"
        y="0.5"
        width={W - 1}
        height={height - 1}
        rx="10"
      />
      <path
        className="ig-titlebar"
        d={`M 0.5 10.5 a 10 10 0 0 1 10 -10 h ${W - 21} a 10 10 0 0 1 10 10 v 17.5 h -${W - 1} z`}
      />
      <circle className="ig-light ig-light-close" cx="16" cy="14" r="5" />
      <circle className="ig-light ig-light-min" cx="32" cy="14" r="5" />
      <circle className="ig-light ig-light-max" cx="48" cy="14" r="5" />
      {children}
    </g>
  );
}

/** Step 1: the search field over the desktop with "Terminal" typed into it. */
export function SpotlightScene() {
  return (
    <svg className="ig-scene" viewBox={`0 0 ${W} 112`} aria-hidden="true" focusable="false">
      <rect className="ig-desktop" width={W} height="112" rx="10" />
      <MenuBar />
      <g transform="translate(50 46)">
        <rect className="ig-field" width="220" height="40" rx="10" />
        <circle className="ig-field-glyph" cx="20" cy="20" r="6" />
        <path className="ig-field-glyph" d="M 24.5 24.5 l 5 5" />
        <text className="ig-field-text" x="36" y="25">
          Terminal
        </text>
        <rect className="ig-caret" x="103" y="11" width="1.5" height="18" />
      </g>
    </svg>
  );
}

/** Step 3: a Terminal window with the line pasted after the prompt. */
export function PasteScene({ command }: { command: string }) {
  return (
    <svg className="ig-scene" viewBox={`0 0 ${W} 100`} aria-hidden="true" focusable="false">
      <Window y={0} height={100} dark>
        <text className="ig-term-title" x={W / 2} y="18" textAnchor="middle">
          Terminal
        </text>
        <text className="ig-term-prompt" x="14" y="50">
          ~ %
        </text>
        {/* Squeezed to the window rather than wrapped: the line is one line,
            whatever the visitor's fonts do to it. */}
        <text
          className="ig-term-text"
          x="38"
          y="50"
          textLength={W - 52}
          lengthAdjust="spacingAndGlyphs"
        >
          {command}
        </text>
        <rect className="ig-caret ig-caret-dark" x="38" y="60" width="6" height="12" />
      </Window>
    </svg>
  );
}

/** Step 4: the script reporting what it did, and the app's icon arriving in the menu bar. */
export function ArriveScene({ name }: { name: string }) {
  return (
    <svg className="ig-scene" viewBox={`0 0 ${W} 132`} aria-hidden="true" focusable="false">
      <rect className="ig-desktop" width={W} height="132" rx="10" />
      <MenuBar>
        {/* The new menu-bar icon, in the product's colour, at the end of the row. */}
        <g className="ig-arrival" transform={`translate(${W - 100} 11)`}>
          <circle className="ig-arrival-halo" r="10" />
          <rect className="ig-arrival-icon" x="-6" y="-6" width="12" height="12" rx="3.5" />
        </g>
      </MenuBar>
      <Window y={34} height={98} dark>
        <text className="ig-term-title" x={W / 2} y="18" textAnchor="middle">
          Terminal
        </text>
        <text className="ig-term-text ig-term-dim" x="14" y="44">
          Downloading {name}…
        </text>
        <text className="ig-term-text ig-term-dim" x="14" y="58">
          Checking the signature…
        </text>
        <text className="ig-term-text ig-term-dim" x="14" y="72">
          Moving it to Applications…
        </text>
        <text className="ig-term-text ig-term-ok" x="14" y="86">
          Opening {name}. Done.
        </text>
      </Window>
    </svg>
  );
}

/** Step 5: a system prompt with a switch in it, the shape of the one macOS shows. */
export function PermissionScene() {
  return (
    <svg className="ig-scene" viewBox={`0 0 ${W} 112`} aria-hidden="true" focusable="false">
      <rect className="ig-desktop" width={W} height="112" rx="10" />
      <MenuBar />
      <g transform="translate(70 36)">
        <rect className="ig-prompt" width="180" height="64" rx="10" />
        <path
          className="ig-prompt-glyph"
          d="M 22 12 l 9 4 v 8 c 0 6 -4 10 -9 12 c -5 -2 -9 -6 -9 -12 v -8 z"
        />
        <rect className="ig-prompt-line" x="42" y="14" width="96" height="6" rx="3" />
        <rect
          className="ig-prompt-line ig-prompt-line-2"
          x="42"
          y="26"
          width="72"
          height="6"
          rx="3"
        />
        <g transform="translate(140 38)">
          <rect className="ig-switch" width="28" height="16" rx="8" />
          <circle className="ig-switch-knob" cx="20" cy="8" r="6" />
        </g>
      </g>
    </svg>
  );
}
