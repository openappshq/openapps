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
import NotchScene from "../NotchScene";
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
    "two or more colours, an angle, and the blend drawn at your display's native pixels",
  ],
  [
    "Mesh",
    "soft colour fields that meet the way ink does on wet paper; move the points, get another",
  ],
  ["Pattern", "grids, stripes, dots and tiles, with the spacing and the colours yours to set"],
  [
    "Solid + grain",
    "one colour with a little film grain, true black included, for a desktop that stays out of the way",
  ],
  [
    "Pixelize and dither",
    "your own photo as pixel art, or through Bayer, Floyd–Steinberg, blue noise, halftone or ASCII; it never leaves your Mac",
  ],
  [
    "Tint and palette",
    "a duotone or gradient map over a photo or a generator; a palette pulled from a picture, or one accent colour, interpolated in OKLCH so it never turns to mud",
  ],
  [
    "Pairs",
    "light and dark from one seed, a solar set for the hours of the day, a desktop and phone pair",
  ],
];

const features: { icon: ReactNode; title: string; body: ReactNode }[] = [
  {
    icon: <Sparkles size={20} />,
    title: "Made on the spot.",
    body: "The generators draw the wallpaper on your Mac, at each display's own pixels. No downloads, no library to browse, no account.",
  },
  {
    icon: <Grid2x2 size={20} />,
    title: "Pixelize and dither.",
    body: "Drop in a picture of your own and it becomes pixel art, or halftone, or ASCII. Choose the pixel size; the image stays on your Mac.",
  },
  {
    icon: <Palette size={20} />,
    title: "Tint and palette.",
    body: "A duotone or gradient map over any photo or generator. Pull a palette from a picture, or start from one accent colour.",
  },
  {
    icon: <SunMoon size={20} />,
    title: "Light, dark, and the hours.",
    body: "One seed gives a light and a dark version, or a solar set that follows the day. They are written as one HEIC, so macOS keeps switching after macPaper quits.",
  },
  {
    icon: <Monitor size={20} />,
    title: "Every display, its own.",
    body: (
      <>
        Cropped and fitted per display at native pixels, with palettes that stay readable under the
        menu bar. One wallpaper per display, or per Space, set through macOS's own{" "}
        <code>NSWorkspace</code>.
      </>
    ),
  },
  {
    icon: <Pin size={20} />,
    title: "Stays put.",
    body: "Pin a wallpaper and macPaper keeps a local copy and re-applies it after a login, a wake, a Space change or a display change. It never writes into Apple's wallpaper caches.",
  },
  {
    icon: <Frame size={20} />,
    title: "Drawn around the notch.",
    body: "Compositions that know where the cutout is: a mesh grows out of it, contours part around it. Notchless and external displays get a painted pill instead.",
  },
  {
    icon: <Shuffle size={20} />,
    title: "Seeds, favorites, shuffle.",
    body: (
      <>
        Every wallpaper is a seed. Favorites are seeds; <code>macpaper://s/…</code> rebuilds one on
        another Mac; shuffle on a schedule from them, mark one never-show-this, or take an optional
        daily still to remix.
      </>
    ),
  },
  {
    icon: <FileDown size={20} />,
    title: "Export anywhere.",
    body: "PNG at display size, SVG where the generator is vector, HEIC for a pair. The same still can go on the lock screen, with a plain fallback where macOS ignores it.",
  },
  {
    icon: <Clock size={20} />,
    title: "Past the desktop.",
    body: "A screensaver from the same still, a clock face matched to its palette, subtle motion on the stills that pauses on battery and in full screen, and Now Playing art as a wallpaper.",
  },
  {
    icon: <SlidersHorizontal size={20} />,
    title: "The notch, your way.",
    body: "Open on hover, on click, or both; choose which display hosts it, which way it opens and how wide; hide it in full screen; give it a hotkey. Or turn it off and use the menu bar.",
  },
  {
    icon: <LockKeyhole size={20} />,
    title: "Asks for nothing.",
    body: "No Accessibility, no screen recording, no account, no telemetry. Location is optional, for the solar set; the network is touched only for the license and update checks, and the daily still if you turn it on.",
  },
];

const questions = [
  [
    "What do I need to run it?",
    "macOS 14 Sonoma or later; one Terminal line installs it, or Homebrew. The release is signed with our release certificate. Building from source stays free and needs no key.",
  ],
  [
    "Do I need a Mac with a notch?",
    "No. On a Mac without one, macPaper lives in the menu bar and the same panel opens from there, and notch-aware compositions paint a pill where the notch would be. On a notched Mac you can still turn the notch panel off and use the menu bar instead.",
  ],
  [
    "How do licenses and trials work?",
    `Install macPaper and it works right away for ${TRIAL_DAYS} days on that Mac, with no signup. To keep it, pay ${PRICE} once for ${MACS_PER_LICENSE} Macs, forever. No subscription or account, and nothing is charged when the trial ends: the generators pause until you buy a license or build from source, and the wallpaper you have set stays, because macOS is showing it, not macPaper. Remove a Mac in Settings › License to free a seat, or contact support if you no longer have it.`,
  ],
  [
    "Can I use it offline?",
    `Official builds check the license once a day and work offline for ${OFFLINE_GRACE} after the last successful check. Free source builds never contact the license service.`,
  ],
  [
    "What permissions does it need?",
    "None. Wallpapers are set through macOS's own workspace API, the one System Settings uses, so there is no Accessibility prompt and no screen recording. Location is optional and only used to time a solar set; without it you pick the hours yourself. Nothing to grant, nothing to revoke.",
  ],
  [
    "My wallpaper keeps resetting. Does this fix it?",
    "That is what pinning is for. macPaper keeps its own copy of a pinned wallpaper and sets it again after a login, a wake, a Space change or a display change, through the public API. It never edits Apple's wallpaper caches, so an update cannot leave your desktop in a broken state.",
  ],
  [
    "Does it change the lock screen?",
    "It applies the same still to the lock screen where macOS accepts it. There is no public API for that, so when the login window ignores it macPaper says so instead of pretending.",
  ],
  [
    "What happens to a photo I pixelize or tint?",
    "It is read, processed and written out on your Mac, and never uploaded. The original is not changed.",
  ],
  [
    "Will motion or the clock eat my battery?",
    "Motion on the stills is subtle, pauses on battery and whenever an app is in full screen, and the clock face redraws once a second. If you never turn them on, macPaper does nothing while the panel is closed.",
  ],
  [
    "What does the official build send anywhere?",
    `Official builds of macPaper include a ${TRIAL_DAYS}-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, your images, and how you use the app are never sent. Builds from source never contact the license service. Official builds also fetch our signed update feed once a day to tell you about a new version; that request carries no identifiers, and installing is your call. The optional daily still is fetched only if you turn it on.`,
  ],
  [
    "Why is it not notarized?",
    "The app is signed with the OpenApps HQ Release certificate, the same one for every release, but not sent to Apple. The install script and the cask clear the download quarantine, so it opens without a Gatekeeper prompt; a zip downloaded by hand needs right-click → Open once.",
  ],
  [
    "Can I use the wallpapers somewhere else?",
    "Yes. Export any of them as a PNG, SVG or HEIC, or share the seed; what macPaper makes on your Mac is yours.",
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
              Wallpapers, from the <KeyToken>notch</KeyToken>.
            </motion.h1>
            <div className="hero-grid mp-hero-grid">
              <div className="hero-intro">
                <p>
                  Gradients, meshes, dither, tints, light-and-dark and solar pairs, made on your Mac
                  at each display's own pixels and set from a panel that drops out of the notch.
                  Pinned, they stay.
                </p>
                <div className="hero-actions">
                  <BuyButtons app="macpaper" requirements={REQUIREMENTS} />
                </div>
              </div>
              <div className="mp-hero-stage">
                <NotchScene />
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
                  Nothing comes from a gallery. Each wallpaper is a seed drawn on your Mac, for the
                  display it is going on, and can be redrawn, remixed or shared as often as you
                  like.
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
                <h2 id="app-title">From the notch. Or the menu bar.</h2>
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
