import { useEffect, useRef } from "react";
import type { ReactNode } from "react";
import { Link } from "@heroui/react";
import { motion } from "motion/react";
import { ArrowUpRight, Download, Star } from "lucide-react";
import { enter } from "@openapps/ui/transitions";
import { DEFAULT_REQUIREMENTS } from "./BuyButtons";
import { GITHUB_URL } from "./github";
import { licensingFor, TRIAL_DAYS } from "./licensing";
import KeyToken from "./KeyToken";
import InstallAnimation from "./InstallAnimation";
import InstallCommand from "./InstallCommand";
import "./download.css";

/**
 * Where an app's install button lands. The app installs from one Terminal line
 * (the install script, with Homebrew as the alternative), so the page leads
 * with the command; with a direct installer configured the file starts on its
 * own and everything else is for the person it did not start for, and for the
 * minute after it did.
 */
export default function DownloadPage({
  installCommand,
  installScriptSourceUrl,
  brewCommand,
  downloadUrl: directUrl,
  app,
  name,
  permission,
  permissions = licensingFor(app).permissions,
  arrival = licensingFor(app).arrival,
  requirements = DEFAULT_REQUIREMENTS,
  shareText,
  playgroundHref,
  playgroundLabel,
  header,
  footer,
}: {
  /** `curl … | sh`. Without one, the page says the release is coming soon. */
  installCommand?: string | null;
  /** Where the script is read; the note beside the command links to it. */
  installScriptSourceUrl: string;
  /** `brew install --cask …`, offered under the command as the alternative. */
  brewCommand?: string | null;
  /** An optional direct installer, offered beside the command; never on its own. */
  downloadUrl?: string | null;
  /** Catalogue id, which selects the artwork and the icon. */
  app: string;
  name: string;
  /** The one macOS permission the app needs on first launch; none for an app that asks for nothing. */
  permission?: string;
  /** Everything macOS asks for, as the catalog lists it; the install guide names each. */
  permissions?: readonly string[];
  /** Where the app shows up once it opens, as the catalog says; the install guide's last step. */
  arrival?: string;
  /** The system line under the actions, for an app whose needs differ from the default. */
  requirements?: ReactNode;
  /** The post someone would actually send. Shown in full before they send it. */
  shareText: string;
  playgroundHref: string;
  playgroundLabel: ReactNode;
  header: ReactNode;
  footer: ReactNode;
}) {
  // The script (published with the cask) is the gate; a file is only ever offered beside it.
  const available = !!installCommand;
  const downloadUrl = available ? directUrl : null;
  const start = useRef<HTMLAnchorElement>(null);
  useEffect(() => {
    if (!downloadUrl) return;
    const timer = window.setTimeout(() => start.current?.click(), 500);
    return () => window.clearTimeout(timer);
  }, [downloadUrl]);

  const shareUrl = `https://twitter.com/intent/tweet?${new URLSearchParams({
    text: shareText,
    url: GITHUB_URL,
  })}`;

  return (
    <>
      <Link className="skip-link" href="#download">
        Skip to download
      </Link>
      {header}
      <main className="download-page" id="download">
        <section className="hero" aria-labelledby="download-title">
          <div className="page-width">
            <motion.h1 {...enter} id="download-title">
              {downloadUrl ? (
                <>
                  Thanks for <KeyToken>downloading</KeyToken>
                </>
              ) : available ? (
                <>
                  One line to <KeyToken>install</KeyToken>
                </>
              ) : (
                <>
                  Coming <KeyToken>soon</KeyToken>
                </>
              )}
            </motion.h1>
            <div className="hero-grid">
              <div className="hero-intro">
                <p>
                  {downloadUrl
                    ? `It should start on its own, or paste the command below. Your ${TRIAL_DAYS}-day trial begins the first time you open the app.`
                    : available
                      ? `Paste this into Terminal. Your ${TRIAL_DAYS}-day trial begins the first time you open the app.`
                      : `The ${name} Mac release is coming soon. When it lands, it installs from here with a ${TRIAL_DAYS}-day trial, no signup.`}
                </p>
                {installCommand && (
                  <InstallCommand
                    command={installCommand}
                    name={name}
                    sourceUrl={installScriptSourceUrl}
                    brewCommand={brewCommand}
                    permissions={permissions}
                    arrival={arrival}
                  />
                )}
                <div className="hero-actions">
                  {/* Only the configured official installer; never a guess. */}
                  {downloadUrl && (
                    <Link ref={start} className="button-link primary" href={downloadUrl} download>
                      Start it manually <Download size={18} aria-hidden="true" />
                    </Link>
                  )}
                  <Link className="text-link hero-aside" href={playgroundHref}>
                    {playgroundLabel}
                  </Link>
                </div>
                <p className="buy-note">{requirements}</p>
              </div>
            </div>
          </div>
        </section>

        <section className="install-section" aria-labelledby="install-title">
          <div className="page-width">
            {downloadUrl ? (
              <>
                <h2 id="install-title" className="reveal">
                  Drag it in.
                </h2>
                <div className="install-figure reveal">
                  <InstallAnimation app={app} name={name} />
                  <p>
                    {permission
                      ? `Then open ${name} and allow ${permission} when macOS asks. That is the whole setup.`
                      : `Then open ${name}. It asks for no permissions, so that is the whole setup.`}
                  </p>
                </div>
              </>
            ) : (
              <>
                <h2 id="install-title" className="reveal">
                  {permission ? "Then say yes once." : "Then nothing to grant."}
                </h2>
                <div className="install-figure reveal">
                  {/* No disk image to rehearse: the script puts the app in place and opens it. */}
                  <p>
                    {permission
                      ? `The command puts ${name} in your Applications folder and opens it. Allow ${permission} when macOS asks. That is the whole setup.`
                      : `The command puts ${name} in your Applications folder and opens it. It asks for no permissions, so that is the whole setup.`}
                  </p>
                </div>
              </>
            )}
          </div>
        </section>

        <section className="closing-section page-width" aria-labelledby="share-title">
          <div className="share-field">
            <h2 id="share-title">Say something nice.</h2>
            {/* The exact words that go out, so nobody posts something unread. */}
            <p className="share-draft">{shareText}</p>
            <div className="share-actions">
              <Link
                className="button-link inverse"
                href={shareUrl}
                target="_blank"
                rel="noopener noreferrer"
              >
                Post on X <ArrowUpRight size={16} aria-hidden="true" />
              </Link>
              <Link
                className="button-link share-link"
                href={GITHUB_URL}
                target="_blank"
                rel="noopener noreferrer"
              >
                <Star size={18} aria-hidden="true" /> Star on GitHub
              </Link>
            </div>
          </div>
        </section>
      </main>
      {footer}
    </>
  );
}
