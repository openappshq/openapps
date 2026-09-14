import { ArrowUpRight } from "lucide-react";
import ThanksPage from "../../../shared/ThanksPage";
import { GITHUB_URL } from "../../../shared/github";
import "../styles.css";

export default function Thanks({ kind = "paid" }: { kind?: "paid" | "trial" }) {
  return (
    <>
      <header className="site-header page-width">
        <a
          className="brand"
          href="/openreaction/"
          aria-label="OpenReaction home"
          referrerPolicy="no-referrer"
        >
          <img
            className="brand-symbol"
            src="/openreaction/favicon.svg"
            alt=""
            width="32"
            height="32"
          />
          <span className="brand-name">OpenReaction</span>
        </a>
      </header>
      <ThanksPage app="openreaction" kind={kind} />
      <footer className="site-footer page-width">
        <div className="hq-lockup">
          <img src="/brand/openapps-hq/app-icon.svg" alt="" width="56" height="56" />
          <div>
            <strong>An OpenApps HQ original.</strong>
            <p>Small apps. Room for personality.</p>
          </div>
        </div>
        <div className="footer-links">
          <a href="/" referrerPolicy="no-referrer">
            All OpenApps
          </a>
          <a href={GITHUB_URL} target="_blank" rel="noreferrer">
            GitHub <ArrowUpRight size={14} />
          </a>
        </div>
      </footer>
    </>
  );
}
