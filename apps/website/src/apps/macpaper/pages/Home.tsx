import "@fontsource/ibm-plex-mono/500.css";
import "../styles.css";
import { motion } from "motion/react";
import { Link } from "@heroui/react";
import {
  FileDown,
  Grid2x2,
  LockKeyhole,
  Monitor,
  Shuffle,
  SlidersHorizontal,
  Sparkles,
  Star,
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
  ["Gradient", "two or more colours, an angle, and the blend drawn at your display's size"],
  [
    "Mesh",
    "soft colour fields that meet the way ink does on wet paper; move the points, get another",
  ],
  ["Pattern", "grids, stripes, dots and tiles, with the spacing and the colours yours to set"],
  ["Solid + grain", "one colour with a little film grain, for a desktop that stays out of the way"],
  [
    "Pixelize",
    "your own photo as pixel art: pick the pixel size, keep the palette; it never leaves your Mac",
  ],
];

const features: { icon: ReactNode; title: string; body: ReactNode }[] = [
  {
    icon: <Sparkles size={20} />,
    title: "Made on the spot.",
    body: "Four generators draw the wallpaper on your Mac, at each display's own size. No downloads, no library to browse, no account.",
  },
  {
    icon: <Grid2x2 size={20} />,
    title: "Pixelize a photo.",
    body: "Drop in a picture of your own and it becomes pixel art. Choose the pixel size; the image stays on your Mac.",
  },
  {
    icon: <Monitor size={20} />,
    title: "Every display, its own.",
    body: (
      <>
        Set one wallpaper per display, or the same everywhere, through macOS's own{" "}
        <code>NSWorkspace</code>. Nothing to grant.
      </>
    ),
  },
  {
    icon: <Shuffle size={20} />,
    title: "Shuffle on a schedule.",
    body: "A fresh wallpaper on the interval you set. Turn it off and the current one stays.",
  },
  {
    icon: <Star size={20} />,
    title: "Keep favorites.",
    body: "Star the ones you like. They stay in the panel, one click from being back on the desktop.",
  },
  {
    icon: <FileDown size={20} />,
    title: "Export PNG or SVG.",
    body: "Take a wallpaper out as a PNG at display size, or as an SVG where the generator is vector, and use it anywhere.",
  },
  {
    icon: <SlidersHorizontal size={20} />,
    title: "The notch, your way.",
    body: "Open on hover, on click, or both; choose which display hosts it, which way it opens and how wide; hide it in full screen; give it a hotkey. Or turn it off and use the menu bar.",
  },
  {
    icon: <LockKeyhole size={20} />,
    title: "Asks for nothing.",
    body: "No Accessibility, no screen recording, no account, no telemetry. The only calls are the license check and the update check.",
  },
];

const questions = [
  [
    "What do I need to run it?",
    "macOS 14 Sonoma or later, and Homebrew to install it. The release is signed with our release certificate. Building from source stays free and needs no key.",
  ],
  [
    "Do I need a Mac with a notch?",
    "No. On a Mac without one, macPaper lives in the menu bar and the same panel opens from there. On a notched Mac you can still turn the notch panel off and use the menu bar instead.",
  ],
  [
    "How do licenses and trials work?",
    `Install macPaper and it works right away for ${TRIAL_DAYS} days on that Mac, with no signup. To keep it, pay ${PRICE} once for ${MACS_PER_LICENSE} Macs, forever. No subscription or account, and nothing is charged when the trial ends: the generators pause until you buy a license or build from source, and the wallpaper you have set stays. Remove a Mac in Settings › License to free a seat, or contact support if you no longer have it.`,
  ],
  [
    "Can I use it offline?",
    `Official builds check the license once a day and work offline for ${OFFLINE_GRACE} after the last successful check. Free source builds never contact the license service.`,
  ],
  [
    "What permissions does it need?",
    "None. Wallpapers are set through macOS's own workspace API, the one System Settings uses, so there is no Accessibility prompt and no screen recording. Nothing to grant, nothing to revoke.",
  ],
  [
    "What happens to a photo I pixelize?",
    "It is read, pixelized and written out on your Mac, and never uploaded. The original is not changed.",
  ],
  [
    "What does the official build send anywhere?",
    `Official builds of macPaper include a ${TRIAL_DAYS}-day free trial with no signup. To keep it to one trial per Mac, the app sends a one-way hash of your Mac’s hardware ID (it can’t be turned back into the ID or linked across our apps) to our trial registry once, when the trial starts. If you buy a license, the app checks it with Dodo Payments, our payment provider: the license key and an activation ID are sent when you activate and once a day after that. Your Mac’s name, your images, and how you use the app are never sent. Builds from source never contact the license service. Official builds also fetch our signed update feed once a day to tell you about a new version; that request carries no identifiers, and installing is your call.`,
  ],
  [
    "Why is it not notarized?",
    "The app is signed with the OpenApps HQ Release certificate, the same one for every release, but not sent to Apple. The cask clears the download quarantine, so it opens without a Gatekeeper prompt; a zip downloaded by hand needs right-click → Open once.",
  ],
  [
    "Can I use the wallpapers somewhere else?",
    "Yes. Export any of them as a PNG or SVG; what macPaper makes on your Mac is yours.",
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
                  Gradients, meshes, patterns and pixel art, made on your Mac and set on every
                  display, from a panel that drops out of the notch.
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
                  Nothing comes from a gallery. Each wallpaper is drawn on your Mac, for the display
                  it is going on, and can be redrawn as often as you like.
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
