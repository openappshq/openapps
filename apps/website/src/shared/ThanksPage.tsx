import { ArrowUpRight, Check, Copy, ExternalLink } from "lucide-react";
import { useEffect, useState } from "react";
import { products } from "../catalog";
import { licensingFor, MACS_PER_LICENSE, SUPPORT_URL } from "./licensing";
import { activateUrl, cleanedUrl, parseCheckoutReturn, type CheckoutReturn } from "./thanks";

function readCheckoutReturn(): CheckoutReturn {
  const result = parseCheckoutReturn(location.search);
  // The key and email live only in this page's memory: drop them from the address bar
  // (and history) right away so they are never bookmarked, shared or logged.
  const cleaned = cleanedUrl(location.href);
  if (cleaned !== location.pathname + location.search + location.hash) {
    history.replaceState(history.state, "", cleaned);
  }
  return result;
}

function KeyRow({ licenseKey }: { licenseKey: string }) {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1800);
    return () => clearTimeout(timer);
  }, [copied]);
  return (
    <div className="license-key">
      <code>{licenseKey}</code>
      <button
        type="button"
        aria-label={copied ? "Copied" : "Copy license key"}
        onClick={() => {
          void navigator.clipboard?.writeText(licenseKey).then(() => setCopied(true));
        }}
      >
        {copied ? <Check size={16} aria-hidden="true" /> : <Copy size={16} aria-hidden="true" />}
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}

function Support({ size = 14 }: { size?: number }) {
  return (
    <a href={SUPPORT_URL}>
      Contact support <ArrowUpRight size={size} aria-hidden="true" />
    </a>
  );
}

/**
 * The page checkout returns to. Shows the key(s) once and never stores or
 * sends them. With an `app` and exactly one key it offers the app's deep link;
 * otherwise (several keys from a bundle, or the site-wide page) it lists every
 * key and points at each app.
 */
export default function ThanksPage({ app }: { app?: string }) {
  const licensing = app ? licensingFor(app) : null;
  const [checkout] = useState(readCheckoutReturn);
  const failed = checkout.status !== null && checkout.status !== "succeeded";
  const single = licensing && checkout.keys.length === 1 ? checkout.keys[0]! : null;
  const appName = licensing?.name ?? "the app";

  if (failed) {
    return (
      <main className="thanks-page page-width">
        <span className="eyebrow">Checkout</span>
        <h1>
          That didn’t
          <br />
          <span>go through.</span>
        </h1>
        <p className="thanks-lead">
          The payment came back as <code>{checkout.status}</code>, so no license was issued and
          nothing was charged. You can try again
          {licensing ? ` from the ${licensing.name} page` : ""}, or write to us if something looks
          wrong.
        </p>
        <div className="thanks-actions">
          <a className="button-link primary" href={licensing?.pageUrl ?? "/"}>
            {licensing ? `Back to ${licensing.name}` : "Back to the apps"}
          </a>
          <span className="thanks-note" style={{ marginTop: 0 }}>
            <Support size={16} />
          </span>
        </div>
      </main>
    );
  }

  return (
    <main className="thanks-page page-width">
      <span className="eyebrow">Thank you</span>
      <h1>
        {licensing ? `${licensing.name} is` : "Your keys are"}
        <br />
        <span>{licensing ? "yours." : "ready."}</span>
      </h1>
      {checkout.keys.length === 0 ? (
        <p className="thanks-lead">
          Check your email for your license key
          {checkout.email && (
            <>
              {" "}
              at <strong>{checkout.email}</strong>
            </>
          )}
          . Each key works on up to {MACS_PER_LICENSE} Macs.
        </p>
      ) : (
        <>
          <p className="thanks-lead">
            {checkout.keys.length === 1
              ? `Here’s your license key. It works on up to ${MACS_PER_LICENSE} Macs`
              : `Here are your license keys. Paste each key into its app — each app recognises its own key, and every key works on up to ${MACS_PER_LICENSE} Macs`}
            {checkout.email && (
              <>
                , and a copy is on its way to <strong>{checkout.email}</strong>
              </>
            )}
            .
          </p>
          <div className="license-keys">
            {checkout.keys.map((key) => (
              <KeyRow key={key} licenseKey={key} />
            ))}
          </div>
          <div className="thanks-actions">
            {single && licensing ? (
              <>
                <a className="button-link primary" href={activateUrl(licensing.scheme, single)}>
                  Open {licensing.name} <ExternalLink size={18} aria-hidden="true" />
                </a>
                <span className="thanks-note" style={{ marginTop: 0 }}>
                  Pre-fills the key in {licensing.name}; you confirm before it activates.
                </span>
              </>
            ) : (
              products.map((product) => (
                <a key={product.id} className="button-link secondary" href={`${product.route}/`}>
                  Get {product.name}
                </a>
              ))
            )}
          </div>
        </>
      )}

      <ol className="thanks-steps" aria-label="Setup steps">
        <li>
          <span>01</span>
          <div>
            <h2>Install {appName}</h2>
            <p>Move it to Applications and open it. Grant the permissions macOS asks for.</p>
          </div>
        </li>
        <li>
          <span>02</span>
          <div>
            <h2>Open Settings › License</h2>
            <p>Click the menu-bar icon, choose Settings, then the License tab.</p>
          </div>
        </li>
        <li>
          <span>03</span>
          <div>
            <h2>Paste your key</h2>
            <p>
              Paste the key and click Activate. {licensing ? licensing.name : "The app"} checks it
              once and you’re done.
            </p>
          </div>
        </li>
      </ol>

      <p className="thanks-note">
        Lost a Mac or need help? <Support />. This page keeps your key only in memory: reload it and
        the key is gone, so copy it now.
      </p>
    </main>
  );
}
