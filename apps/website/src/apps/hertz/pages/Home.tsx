import "@fontsource/ibm-plex-mono/500.css";
import "../styles.css";
import { motion } from "motion/react";
import { Link } from "@heroui/react";
import { ArrowUpRight, Cpu, LockKeyhole, Stethoscope, Terminal } from "lucide-react";
import { enter } from "@openapps/ui/transitions";
import DashboardPreview from "../DashboardPreview";
import KeyToken from "../../../shared/KeyToken";
import HqBadge from "../../../shared/HqBadge";
import HertzInstall from "../HertzInstall";
import { MarketingHeader, MarketingFooter, Legend } from "../../../shared/MarketingChrome";
import Questions from "../../../shared/Questions";
import { GITHUB_URL } from "../../../shared/github";
import { brewCasks } from "../../../shared/licensing";

const readings: [string, string][] = [
  ["CPU", "overall and per core, load average, temperature, fan speed and the kernel's thermal pressure"],
  ["Memory", "used, free and swap, with the pressure level macOS itself acts on"],
  ["Disk", "free space on the startup volume, and live read and write throughput across every attached disk"],
  ["Network", "up and down, the interface, local IP, whether a VPN is on, and the Wi-Fi name where macOS still shares it without Location access"],
  ["Battery", "charge, time left, live power draw, health, cycles, temperature, adapter wattage and your mouse, keyboard and trackpad"],
  ["Processes", "a tree grouped by app with subtree totals, sortable by CPU or memory, with copy, reveal and Activity Monitor a right-click away"],
  ["Diagnosis", "what is slow right now, the last few pressure changes, and a copyable snapshot for a support thread"],
  ["Sleep blockers", "which app is keeping the Mac awake, shown only while one is"],
  ["Cleanup Scout", "a read-only scan of known regenerable developer caches with their sizes; Hertz never deletes, you decide in the Finder"],
];

const questions = [
  [
    "What does it cost?",
    "Nothing. Hertz is free and MIT licensed, with no license key, no trial and no account. Install it with Homebrew or build it from source.",
  ],
  [
    "What do I need to run it?",
    "macOS 14 Sonoma or later. The release is a universal binary; per-core detail and temperatures are best on Apple silicon.",
  ],
  [
    "What permissions does it need?",
    "None. Everything comes from the kernel's own interfaces: Mach, libproc, IOKit, the SMC and CoreWLAN. Nothing to grant, nothing to revoke.",
  ],
  [
    "Does it send anything anywhere?",
    "No. Readings are shown and dropped; the only thing Hertz stores is your settings. It never checks for updates on its own, either: that is Homebrew's job.",
  ],
  [
    "How accurate is it?",
    "Per-process CPU and memory match Activity Monitor: CPU time is converted from Mach absolute-time units and memory is the physical footprint, not RSS. A verifier in the repository cross-checks every reading against df, vm_stat, top, ps, pmset and ioreg.",
  ],
  [
    "Why is it not notarized?",
    "The app is signed with the OpenApps HQ Release certificate, the same one for every release, but not sent to Apple. The cask clears the download quarantine, so it opens without a Gatekeeper prompt; a zip downloaded by hand needs right-click → Open once.",
  ],
  [
    "Can Cleanup Scout delete something I need?",
    "No: it deletes nothing at all. It lists a short allowlist of regenerable caches under your home folder (Xcode's DerivedData, SwiftPM, Homebrew downloads, npm, pip, uv, Ruff) with their sizes, refuses anything else, and reveals a folder in the Finder when you ask. Removing it is your call, there.",
  ],
  [
    "Can it quit a process?",
    "No. A row in the list is a two-second-old snapshot, and a process ID can be reused by something else in that time, so Hertz never sends a signal. The context menu opens Activity Monitor instead, where what you quit is what you see.",
  ],
];

export default function App() {
  return (
    <>
      <Link className="skip-link" href="#see">
        Skip to the dashboard
      </Link>
      <MarketingHeader
        productId="hertz"
        links={[
          { label: "What it shows", href: "#see" },
          { label: "Install", href: "#install" },
          { label: "Questions", href: "#questions" },
        ]}
        action={{ label: "Install with Homebrew", href: "#install", icon: <Terminal size={16} /> }}
      />
      <main>
        <section className="hero" aria-labelledby="hero-title">
          <div className="page-width">
            <div className="hero-kicker">
              <HqBadge />
            </div>
            <motion.h1 {...enter} id="hero-title">
              Your Mac, <KeyToken>live</KeyToken>.
            </motion.h1>
            <div className="hero-grid">
              <div className="hero-intro">
                <p>
                  A native menu-bar system monitor. CPU, memory, disk, network, battery and thermals,
                  read straight from the kernel every two seconds.
                </p>
                <div className="hero-actions">
                  <Link className="button-link primary" href="#install">
                    Install with Homebrew <Terminal size={18} aria-hidden="true" />
                  </Link>
                  <Link
                    className="button-link secondary"
                    href={`${GITHUB_URL}/tree/main/apps/hertz`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Browse the source <ArrowUpRight size={18} aria-hidden="true" />
                  </Link>
                  <p className="buy-note">
                    Free and open source <span aria-hidden="true">·</span> macOS 14+{" "}
                    <span aria-hidden="true">·</span> No permissions
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="see-section" id="see" aria-labelledby="see-title">
          <div className="page-width see-grid">
            <div className="see-text">
              <div className="reveal">
                <Legend index="01">What it shows</Legend>
                <h2 id="see-title">One click. The whole machine.</h2>
                <p className="see-lead">
                  A health score first, then a card for every reading. Charts and bars carry the
                  state; the numbers stay legible.
                </p>
              </div>
              <dl className="readings reveal-group">
                {readings.map(([name, detail]) => (
                  <div key={name}>
                    <dt>{name}</dt>
                    <dd>{detail}</dd>
                  </div>
                ))}
              </dl>
            </div>
            <div className="see-stage reveal">
              <DashboardPreview />
            </div>
          </div>
        </section>

        <section className="mac-section" aria-labelledby="mac-title">
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend>The Mac app</Legend>
                <h2 id="mac-title">Native, all the way down.</h2>
              </div>
            </div>
            <div className="feature-grid reveal-group">
              <article>
                <span className="feature-icon">
                  <Cpu size={20} />
                </span>
                <h3>Read from the kernel.</h3>
                <p>
                  No shelling out to <code>top</code>. Mach, libproc and IOKit, the way Activity
                  Monitor does it, refreshed every 2 seconds in a few megabytes of memory.
                </p>
              </article>
              <article>
                <span className="feature-icon">
                  <Stethoscope size={20} />
                </span>
                <h3>Says what is slow.</h3>
                <p>
                  A diagnosis names the bottleneck and the app behind it, keeps the last few pressure
                  changes, and copies a snapshot for a support thread.
                </p>
              </article>
              <article>
                <span className="feature-icon">
                  <LockKeyhole size={20} />
                </span>
                <h3>Asks for nothing.</h3>
                <p>
                  No permissions, no account, no telemetry, no update checks. Readings are shown and
                  dropped; only your settings are kept.
                </p>
              </article>
            </div>
          </div>
        </section>

        <section className="install-section" id="install" aria-labelledby="install-title">
          <div className="page-width">
            <div className="section-heading reveal">
              <div>
                <Legend index="02">Install</Legend>
                <h2 id="install-title">One line.</h2>
              </div>
            </div>
            <div className="reveal">
              {/* The cask once it exists (VITE_HERTZ_BREW_CASK); "Coming soon" until then. */}
              <HertzInstall cask={brewCasks.hertz} />
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
                Free.
                <br />
                Native.
                <br />
                Yours.
              </h2>
              <Link className="button-link inverse" href="#install">
                Install with Homebrew <Terminal size={20} aria-hidden="true" />
              </Link>
            </div>
            <img src="/brand/hertz/symbol-ink.svg" alt="" width="300" height="300" />
          </div>
        </section>
      </main>
      <MarketingFooter productId="hertz" />
    </>
  );
}
