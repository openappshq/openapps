import { useEffect, useRef } from "react";
import { Link } from "@heroui/react";
import { motion } from "motion/react";
import { ArrowDown, ArrowUpRight, Download, Star } from "lucide-react";
import { enter } from "@openapps/ui/transitions";
import { SiteFooter, SiteHeader } from "../SiteChrome";
import { GITHUB_URL } from "../../../shared/github";
import "../styles.css";
import "../download.css";

const shareUrl = `https://twitter.com/intent/tweet?${new URLSearchParams({
  text: "Meet OpenKlack: mechanical keyboard sounds for the keyboard you already own. Free & open source.",
  url: GITHUB_URL,
})}`;

export default function DownloadPage({
  downloadUrl = import.meta.env.VITE_OPENKLACK_MAC_DOWNLOAD_URL,
}: {
  downloadUrl?: string;
}) {
  const retry = useRef<HTMLAnchorElement>(null);
  useEffect(() => {
    if (!downloadUrl) return;
    const timer = window.setTimeout(() => retry.current?.click(), 500);
    return () => window.clearTimeout(timer);
  }, [downloadUrl]);

  return (
    <>
      <Link className="skip-link" href="#download">
        Skip to download
      </Link>
      <SiteHeader />
      <main className="download-page page-width" id="download">
        <motion.section {...enter} className="download-intro" aria-labelledby="download-title">
          <img src="/brand/openklack/app-icon.svg" alt="" width="112" height="112" />
          <span className="download-status">
            {downloadUrl ? "Free & open source" : "Mac release coming soon"}
          </span>
          <h1 id="download-title">
            {downloadUrl ? (
              <>
                Let’s make
                <br />
                <span>some noise.</span>
              </>
            ) : (
              <>
                OpenKlack.
                <br />
                <span>Coming to Mac.</span>
              </>
            )}
          </h1>
          {downloadUrl ? (
            <p>
              Your download should start automatically. <br />
              If it doesn’t,{" "}
              <Link ref={retry} href={downloadUrl} download className="download-retry">
                download again <Download size={16} />
              </Link>
              .
            </p>
          ) : (
            <>
              <p>
                We’re preparing the first public Mac release. <br />
                Try the sounds while we get it ready.
              </p>
              <Link className="button-link primary" href="/OpenKlack/#playground">
                Try the sounds <ArrowDown size={18} />
              </Link>
            </>
          )}
          <span className="download-requirements">
            macOS 14+ · Apple Silicon{!downloadUrl && " · Planned support"}
          </span>
        </motion.section>

        <section className="download-install" aria-labelledby="install-title">
          <div className="download-section-heading">
            <h2 id="install-title">
              {downloadUrl ? "Make yourself at home." : "When it lands, you’re three steps away."}
            </h2>
          </div>
          <ol>
            <li>
              <span>01</span>
              <div>
                <h3>Move to Applications</h3>
                <p>Open the download and drag OpenKlack into Applications.</p>
              </div>
            </li>
            <li>
              <span>02</span>
              <div>
                <h3>Allow keyboard access</h3>
                <p>Open OpenKlack and enable Input Monitoring when prompted.</p>
              </div>
            </li>
            <li>
              <span>03</span>
              <div>
                <h3>Pick your sound</h3>
                <p>Choose a sound, set the volume, and get back to typing.</p>
              </div>
            </li>
          </ol>
        </section>

        <section className="download-community" aria-labelledby="community-title">
          <div>
            <h2 id="community-title">Small app. Made better together.</h2>
            <p>A star or a little word of mouth goes a long way.</p>
          </div>
          <div className="download-socials">
            <Link
              className="button-link inverse"
              href={GITHUB_URL}
              target="_blank"
              rel="noopener noreferrer"
            >
              <Star size={18} /> Star on GitHub <ArrowUpRight size={16} />
            </Link>
            <Link
              className="button-link share-link"
              href={shareUrl}
              target="_blank"
              rel="noopener noreferrer"
            >
              Post on X <ArrowUpRight size={16} />
            </Link>
          </div>
        </section>
      </main>
      <SiteFooter />
    </>
  );
}
