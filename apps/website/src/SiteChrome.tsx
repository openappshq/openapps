import { Link } from "@heroui/react";
import { motion } from "motion/react";
import { ArrowUpRight, Download } from "lucide-react";

const MotionLink = motion.create(Link);

export function SiteHeader() {
  return (
    <header className="site-header page-width" id="top">
      <Link className="brand" href="/#top" aria-label="OpenKlack home">
        <img
          className="brand-symbol"
          src="/brand/openklack/symbol-ink.svg"
          alt=""
          width="36"
          height="36"
        />
        <img
          className="brand-wordmark"
          src="/brand/openklack/wordmark-ink.svg"
          alt="OpenKlack"
          width="150"
          height="34"
        />
      </Link>
      <nav aria-label="Main navigation">
        <Link href="/#desktop">The Mac app</Link>
        <Link href="/#questions">Questions</Link>
        <MotionLink
          whileHover={{ y: -2 }}
          whileTap={{ scale: 0.98 }}
          className="button-link small primary"
          href="/download/"
        >
          Download for Mac <Download size={16} />
        </MotionLink>
      </nav>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="site-footer page-width">
      <div className="hq-lockup">
        <img src="/brand/openapps-hq/symbol-ink.svg" alt="" width="40" height="40" />
        <div>
          <img
            src="/brand/openapps-hq/wordmark-ink.svg"
            alt="OpenApps HQ"
            width="150"
            height="27"
          />
          <p>Small apps. Room for personality.</p>
        </div>
      </div>
      <div>
        <span>OpenKlack / 2026</span>
        <Link href="https://github.com/openappshq/openklack" target="_blank" rel="noreferrer">
          GitHub <ArrowUpRight size={14} />
        </Link>
      </div>
    </footer>
  );
}
