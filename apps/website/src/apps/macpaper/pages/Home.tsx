import "@fontsource/ibm-plex-mono/500.css";
import "../styles.css";
import { motion } from "motion/react";
import { Link } from "@heroui/react";
import {
  Clock,
  FileDown,
  Frame,
  Grid2x2,
  LockKeyhole,
  Monitor,
  Palette,
  Pin,
  Shuffle,
  SlidersHorizontal,
  Sparkles,
  SunMoon,
} from "lucide-react";
import type { ReactNode } from "react";
import { enter } from "@openapps/ui/transitions";
import PanelScene from "../PanelScene";
import PaperGallery from "../PaperGallery";
import MacPaperInstall from "../MacPaperInstall";
import KeyToken from "../../../shared/KeyToken";
import HqBadge from "../../../shared/HqBadge";
import { MarketingHeader, MarketingFooter, Legend } from "../../../shared/MarketingChrome";
import Questions from "../../../shared/Questions";
import BuyButtons from "../../../shared/BuyButtons";
import InstallLink from "../../../shared/InstallLink";
import { installAction } from "../../../shared/installAction";
import {
  licensingFor,
  MACS_PER_LICENSE,
  OFFLINE_GRACE,
  TRIAL_DAYS,
} from "../../../shared/licensing";

const licensing = licensingFor("macpaper");
const { price: PRICE } = licensing;

/* Sets wallpapers through macOS's own API, so the default "Apple Silicon" line
   would undersell it and a permissions line would be wrong. */
const REQUIREMENTS = (
  <>
    macOS 14+ <span aria-hidden="true">·</span> No permissions
  </>
);

const makers: [string, string][] = [
  [
    "Gradient",
    "linear, radial or conic; two to six stops; blended in OKLCH so there is no grey dip between saturated colours",
  ],
  [
    "Mesh",
    "a grid of colour points, up to six colours, jitter and softness; the seed places the points and picks their colours",
  ],
  ["Pattern", "dots, lines, checks, noise or contours; two colours, a scale, an angle"],
  [
    "Solid",
    "one colour, or True black: exact zeros with every finish off, the ground Liquid Glass reads best on",
  ],
  [
    "Pixelize",
    "your own photo in blocks of 4 to 64 pixels, with an optional palette of 2 to 32 colours; it never leaves your Mac",
  ],
  [
    "Dither",
    "the same photo through Bayer, Floyd–Steinberg, blue noise, halftone or ASCII, in ink and paper or a reduced palette",
  ],
  [
    "Finishes",
    "tint, duotone, gradient map, film grain, and a shade over the menu-bar strip when the panel says the menu bar reads low",
  ],
];

const features: { icon: ReactNode; title: string; body: ReactNode }[] = [
  {
    icon: <Sparkles size={20} />,
    title: "Made on the spot.",
    body: "Every wallpaper is a document: a generator, its knobs and a seed, rendered on your Mac at each display's exact pixels. No downloads, no library to browse, no account.",
  },
  {
    icon: <Grid2x2 size={20} />,
    title: "Pixelize and dither.",
    body: "Drop in a picture of your own and it becomes pixel art, halftone or ASCII. Drag the focal point, choose fill, fit or stretch per display; the image stays on your Mac.",
  },
  {
    icon: <Palette size={20} />,
    title: "Colours from anywhere.",
    body: "Pull a palette from a photo, expand your Mac's accent colour into one, or use the built-in sets. Everything interpolates in OKLCH so nothing lands in the grey.",
  },
  {
    icon: <SunMoon size={20} />,
    title: "Light, dark, and the hours.",
    body: "Every document has a light and a dark side, or a time-of-day set at 4, 8 or 16 moments. Applied as one HEIC, the format macOS's own dynamic desktops use, so macOS keeps switching after macPaper quits.",
  },
  {
    icon: <Monitor size={20} />,
    title: "Every display, its own.",
    body: (
      <>
        Rendered at each display's native pixels and handed to macOS through{" "}
        <code>NSWorkspace</code>; a 5120×1440 ultrawide gets a 5120×1440 plate, never an upscale.
        One document everywhere, or one per display.
      </>
    ),
  },
  {
    icon: <Pin size={20} />,
    title: "Stays put.",
    body: "The applied file is macPaper's own copy, never a write into Apple's caches. Keep it applied, and macPaper sets it again whenever macOS shows something else: at launch, on wake, on unlock, on a Space or display change.",
  },
  {
    icon: <Frame size={20} />,
    title: "Drawn around the notch.",
    body: "A mesh can emerge from the cutout, a pattern's contours part around it, and a display without a notch gets a painted pill for symmetry. The composition is part of the document and renders per display.",
  },
  {
    icon: <Shuffle size={20} />,
    title: "Seeds, favorites, shuffle.",
    body: (
      <>
        Share puts <code>macpaper://s/…</code> on the pasteboard, the whole document and never an
        image. Remix is a new seed. Favorites are documents, so they render again for any display.
        Shuffle on a schedule from favorites or fresh, and Never show this keeps one out.
      </>
    ),
  },
  {
    icon: <FileDown size={20} />,
    title: "Export anywhere.",
    body: "PNG at display size, SVG where the generator is vector, a HEIC pair, or a phone pair: the desktop still and a portrait of the same document to AirDrop yourself.",
  },
  {
    icon: <Clock size={20} />,
    title: "Past the desktop.",
    body: "A clock face on the wallpaper layer, below the icons, matched to the applied palette. A screen saver you install into your Screen Savers folder that shows the applied stills and crossfades through favorites.",
  },
  {
    icon: <SlidersHorizontal size={20} />,
    title: "One click in the menu bar.",
    body: "Click the icon, or press ⌥⌘P from anywhere, and the panel opens under it on whatever display the icon is on, as tall as its content. Pick how wide it is and whether it hides in full screen; the icon again, Escape or a click outside closes it.",
  },
  {
    icon: <LockKeyhole size={20} />,
    title: "Asks for nothing.",
    body: "No Accessibility, no Screen Recording, no Location, no account, no telemetry. Nothing is uploaded; the only network calls are the license check and the update check.",
  },
];

const questions = [
  [
    "What do I need to run it?",
    "macOS 14 Sonoma or later; one Terminal line installs it, or Homebrew. The release is signed with our release certificate. Building from source stays free and needs no key.",
  ],
  [
    "Do I need a Mac with a notch?",
    "No. macPaper lives in the menu bar on every Mac. The notch only matters to the wallpaper: on a Mac with one, a mesh can emerge from the cutout or a pattern part around it, and on a Mac without one the same compositions paint a pill where it would be.",
  ],
  [
    "How do licenses and trials work?",
    `Install macPaper and it works right away for ${TRIAL_DAYS} days on that Mac, with no signup. To keep it, pay ${PRICE} once for ${MACS_PER_LICENSE} Macs, forever. No subscription or account, and nothing is charged when the trial ends: generating, Shuffle, Apply and Export pause until you buy a license or build from source, and the wallpaper you have set stays, because macPaper never removes what it set. Remove a Mac in Settings › License to free a seat, or contact support if you no longer have it.`,
  ],
  [
    "Can I use it offline?",
    `Official builds check the license once a day and work offline for ${OFFLINE_GRACE} after the last successful check. Free source builds never contact the license service.`,
  ],
  [
    "What permissions does it need?",
    "None. Wallpapers are set through macOS's own workspace API, the one System Settings uses, so there is no Accessibility prompt and no Screen Recording. The time-of-day pair follows the clock, not the sun, so there is no Location prompt either. Nothing to grant, nothing to revoke.",
  ],
  [
    "My wallpaper keeps resetting. Does this fix it?",
    "That is what Keep it applied is for. macPaper applies its own copy of the file and sets it again after a launch, a wake, an unlock, a Space change or a display change, through the public API. It never writes into Apple's wallpaper caches, so an OS update that clears them cannot take your desktop with it.",
  ],
  [
    "Can I set a different wallpaper on each Space?",
    "Apply → Every Space is the default: it applies now and re-applies as each Space becomes active, so they all match. This Space only applies once to the Space you are on. macOS gives no public identity for a Space, so if it rearranges Spaces automatically that one cannot be followed; Settings says so and points at the toggle.",
  ],
  [
    "Does it change the lock screen?",
    "The lock screen follows the desktop: since macOS Sonoma it shows the current desktop wallpaper, and there is no public way to set a separate one. A light/dark pair follows too. macPaper says this plainly under About instead of pretending otherwise.",
  ],
  [
    "What happens to a photo I pixelize or dither?",
    "It is read, processed and written out on your Mac, and never uploaded. The original is not changed; a copy is kept so a favorite still works after the original moves.",
  ],
  [
    "Does the clock or the screen saver cost battery?",
    "The clock is one window on the desktop level that redraws once a second, hidden in full screen and drawn without a sweeping hand under Reduce Motion. The screen saver needs nothing from the app while it runs. Neither is on until you turn it on; with the panel closed macPaper does nothing.",
  ],
  [
    "What does the official build send anywhere?",
    `Official builds of macPaper include a ${TRIAL_DAYS}-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, your images, and how you use the app are never sent. Builds from source never contact the license service. Official builds also fetch our signed update feed once a day to tell you about a new version; that request carries no identifiers, and installing is your call.`,
  ],
  [
    "Why is it not notarized?",
    "The app is signed with the OpenApps HQ Release certificate, the same one for every release, but not sent to Apple. The install script and the cask clear the download quarantine, so it opens without a Gatekeeper prompt; a zip downloaded by hand needs right-click → Open once.",
  ],
  [
    "Can I use the wallpapers somewhere else?",
    "Yes. Export any of them as a PNG, SVG or HEIC, or share the seed link; what macPaper makes on your Mac is yours.",
  ],
];

export default function App() {
  return (
    <>
      <Link className="skip-link" href="#make">
        Skip to what it makes
      </Link>
      <MarketingHeader
        productId="macpaper"
        links={[
          { label: "What it makes", href: "#make" },
          { label: "The Mac app", href: "#app" },
          { label: "Install", href: "#install" },
          { label: "Questions", href: "#questions" },
        ]}
        action={installAction("macpaper")}
      />
      <main>
        <section className="hero" aria-labelledby="hero-title">
          <div className="page-width">
            <div className="hero-kicker">
              <HqBadge />
            </div>
            <motion.h1 {...enter} id="hero-title">
              Wallpapers, from the <KeyToken>menu bar</KeyToken>.
            </motion.h1>
            <div className="hero-grid mp-hero-grid">
              <div className="hero-intro">
                <p>
                  Gradients, meshes, patterns, dither and pixel art, light-and-dark and time-of-day
                  pairs, made on your Mac at each display's own pixels and set from a panel that
                  opens under its menu bar icon. Stills that macOS keeps showing after the app quits.
                </p>
                <div className="hero-actions">
                  <BuyButtons app="macpaper" requirements={REQUIREMENTS} />
                </div>
              </div>
              <div className="mp-hero-stage">
                <PanelScene />
              </div>
            </div>
          </div>
        </section>

        <section className="make-section" id="make" aria-labelledby="make-title">
          <div className="page-width make-grid">
            <div className="make-text">
              <div className="reveal">
                <Legend index="01">What it makes</Legend>
                <h2 id="make-title">Made here. Not downloaded.</h2>
                <p className="make-lead">
                  Nothing comes from a gallery. Each wallpaper is a document with a seed, drawn on
                  your Mac for the display it is going on, and can be redrawn, remixed or shared as
                  often as you like.
                </p>
              </div>
              <dl className="makers reveal-group">
                {makers.map(([name, detail]) => (
                  <div key={name}>
                    <dt>{name}</dt>
                    <dd>{detail}</dd>
                  </div>
                ))}
              </dl>
            </div>
            <div className="make-stage reveal">
              <PaperGallery />
            </div>
          </div>
        </section>

        <section className="mac-section" id="app" aria-labelledby="app-title">
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend index="02">The Mac app</Legend>
                <h2 id="app-title">Lives in the menu bar.</h2>
              </div>
            </div>
            <div className="feature-grid reveal-group">
              {features.map((feature) => (
                <article key={feature.title}>
                  <span className="feature-icon">{feature.icon}</span>
                  <h3>{feature.title}</h3>
                  <p>{feature.body}</p>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className="install-section" id="install" aria-labelledby="install-title">
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend index="03">Install</Legend>
                <h2 id="install-title">One line.</h2>
              </div>
            </div>
            <div className="reveal">
              {/* Live on the same gate as Buy (VITE_MACPAPER_DODO_PAID_PRODUCT_ID and
                  VITE_MACPAPER_BREW_CASK); "Coming soon" until both are set. */}
              <MacPaperInstall licensing={licensing} />
            </div>
          </div>
        </section>

        <section className="faq-wrap" id="questions" aria-labelledby="faq-title">
          <div className="faq-section page-width">
            <div>
              <h2 id="faq-title">Good questions.</h2>
            </div>
            <Questions items={questions} />
          </div>
        </section>

        <section className="closing-wrap" aria-labelledby="start-title">
          <div className="closing-section page-width">
            <div>
              <h2 id="start-title">
                Drawn.
                <br />
                Dropped.
                <br />
                Yours.
              </h2>
              <InstallLink app="macpaper" className="button-link inverse" />
            </div>
            <img src="/brand/macpaper/symbol-ink.svg" alt="" width="300" height="300" />
          </div>
        </section>
      </main>
      <MarketingFooter productId="macpaper" />
    </>
  );
}
