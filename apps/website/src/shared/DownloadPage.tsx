import { useEffect, useRef } from "react";
import type { ReactNode } from "react";
import { Link } from "@heroui/react";
import { motion } from "motion/react";
import { ArrowUpRight, Download, Star } from "lucide-react";
import { enter } from "@openapps/ui/transitions";
import { GITHUB_URL } from "./github";
import { TRIAL_DAYS } from "./licensing";
import KeyToken from "./KeyToken";
import InstallAnimation from "./InstallAnimation";
import "./download.css";

/**
 * Where an app's Download button lands. The file starts on its own; everything
 * here is for the person it did not start for, and for the minute after it did.
 */
export default function DownloadPage({
  downloadUrl,
  app,
  name,
  permission,
  shareText,
  playgroundHref,
  playgroundLabel,
  header,
  footer,
}: {
  /** The official installer. Without one, the page says the release is coming soon and offers no file. */
  downloadUrl?: string | null;
  /** Catalogue id, which selects the artwork and the icon. */
  app: string;
  name: string;
  /** The one macOS permission the app needs on first launch. */
  permission: string;
  /** The post someone would actually send. Shown in full before they send it. */
  shareText: string;
  playgroundHref: string;
  playgroundLabel: ReactNode;
  header: ReactNode;
  footer: ReactNode;
}) {
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
                    ? `It should start on its own. Your ${TRIAL_DAYS}-day trial begins the first time you open the app.`
                    : `The ${name} Mac release is coming soon. When it lands, it downloads from here with a ${TRIAL_DAYS}-day trial, no signup.`}
                </p>
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
                <p className="buy-note">
                  macOS 14+ <span aria-hidden="true">·</span> Apple Silicon
                </p>
              </div>
            </div>
          </div>
        </section>

        <section className="install-section" aria-labelledby="install-title">
          <div className="page-width">
            <h2 id="install-title" className="reveal">
              Drag it in.
            </h2>
            <div className="install-figure reveal">
              <InstallAnimation app={app} name={name} />
              <p>
                Then open {name} and allow {permission} when macOS asks. That is the whole setup.
              </p>
            </div>
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
