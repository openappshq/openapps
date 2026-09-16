import { ArrowUpRight, ExternalLink } from "lucide-react";
import { useState } from "react";
import { paidProducts } from "../catalog";
import CopyRow from "./CopyRow";
import InstallCommand from "./InstallCommand";
import { licensingFor, MACS_PER_LICENSE, SUPPORT_URL, type AppLicensing } from "./licensing";
import { activateUrl, readCheckoutReturn } from "./thanks";

function Support({ size = 14 }: { size?: number }) {
  return (
    <a href={SUPPORT_URL} referrerPolicy="no-referrer" rel="noreferrer">
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
export default function ThanksPage({
  app,
  asksPermissions = true,
  licensing = app ? licensingFor(app) : null,
}: {
  app?: string;
  /** False for an app that needs no macOS permission, so the install step promises none. */
  asksPermissions?: boolean;
  /** Overrides the environment's licensing (tests). */
  licensing?: AppLicensing | null;
}) {
  const [checkout] = useState(() => readCheckoutReturn(window));
  const unconfirmed = checkout.status !== null && checkout.status !== "succeeded";
  const single = licensing && checkout.keys.length === 1 ? checkout.keys[0]! : null;
  const appName = licensing?.name ?? "the app";
  const seats = `It works on up to ${MACS_PER_LICENSE} Macs`;
  const permissions = asksPermissions ? "Grant the permissions macOS asks for." : "Nothing to grant.";

  if (unconfirmed) {
    return (
      <main className="thanks-page page-width">
        <span className="eyebrow">Checkout</span>
        <h1>
          Not confirmed
          <br />
          <span>just yet.</span>
        </h1>
        <p className="thanks-lead">
          We couldn’t confirm this checkout yet (status: <code>{checkout.status}</code>). If it went
          through, your key is in your email
          {checkout.email && (
            <>
              {" "}
              at <strong>{checkout.email}</strong>
            </>
          )}
          . Otherwise you can try again{licensing ? ` from the ${licensing.name} page` : ""}, or
          write to us.
        </p>
        <div className="thanks-actions">
          <a
            className="button-link primary"
            href={licensing?.pageUrl ?? "/"}
            referrerPolicy="no-referrer"
          >
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
          . {seats}.
        </p>
      ) : (
        <>
          <p className="thanks-lead">
            {checkout.keys.length === 1
              ? `Here’s your license key. ${seats}`
              : `Here are your keys. Paste each key into its app — each app recognises its own key, and every key works on up to ${MACS_PER_LICENSE} Macs`}
            {checkout.email && (
              <>
                , and a copy is on its way to <strong>{checkout.email}</strong>
              </>
            )}
            .
          </p>
          <div className="license-keys">
            {checkout.keys.map((key) => (
              <CopyRow key={key} value={key} label="license key" className="license-key" />
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
              paidProducts.map((product) => (
                <a
                  key={product.id}
                  className="button-link secondary"
                  href={`${product.route}/`}
                  referrerPolicy="no-referrer"
                >
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
            {licensing?.brewCommand ? (
              <>
                {/* The buyer may not have the app yet: the install is one line, right here. */}
                <p>Don’t have it yet? Paste this into Terminal, then open {licensing.name}.</p>
                <InstallCommand command={licensing.brewCommand} />
                <p>
                  {permissions}
                  {licensing.downloadUrl && (
                    <>
                      {" "}
                      Prefer a file?{" "}
                      <a href={licensing.downloadPageUrl} referrerPolicy="no-referrer">
                        Download {licensing.name}
                      </a>
                      .
                    </>
                  )}
                </p>
              </>
            ) : (
              <p>
                Move it to Applications and open it. {permissions}
                {licensing && (
                  <>
                    {" "}
                    Don’t have it yet?{" "}
                    <a href={licensing.downloadPageUrl} referrerPolicy="no-referrer">
                      Get {licensing.name}
                    </a>
                    .
                  </>
                )}
              </p>
            )}
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
