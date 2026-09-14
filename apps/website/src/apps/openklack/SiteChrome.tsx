import { Link } from "@heroui/react";
import { motion } from "motion/react";
import { ArrowLeft, ArrowUpRight, Download } from "lucide-react";

import StarButton from "../../shared/StarButton";

const MotionLink = motion.create(Link);

export function SiteHeader() {
  return (
    <header className="site-header page-width" id="top">
      <Link className="brand" href="/OpenKlack/#top" aria-label="OpenKlack home">
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
        <Link href="/OpenKlack/#desktop">The Mac app</Link>
        <Link href="/OpenKlack/#questions">Questions</Link>
        <StarButton />
        <MotionLink
          whileHover={{ y: -2 }}
          whileTap={{ scale: 0.98 }}
          className="button-link small primary"
          href="/OpenKlack/download/"
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
      <Link className="hq-lockup" href="/" aria-label="Explore all OpenApps">
        <img src="/brand/openapps-hq/symbol-ink.svg" alt="" width="40" height="40" />
        <div>
          <img
            src="/brand/openapps-hq/wordmark-ink.svg"
            alt="OpenApps HQ"
            width="150"
            height="27"
          />
          <p>
            <ArrowLeft size={14} /> All OpenApps
          </p>
        </div>
      </Link>
      <div>
        <span>OpenKlack / 2026</span>
        <Link href="https://github.com/openappshq/openklack" target="_blank" rel="noreferrer">
          GitHub <ArrowUpRight size={14} />
        </Link>
      </div>
    </footer>
  );
}
