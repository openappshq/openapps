import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { CHECKOUT_GLOBAL } from "./checkoutCapture";
import { dodoConfigFrom, licensingFor } from "./licensing";
import ThanksPage from "./ThanksPage";

const dodo = dodoConfigFrom({ VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "pdt_okPaid" });
const casks = { openklack: "openappshq/tap/openklack" };
const command = "curl -fsSL https://openapps.space/install/openklack | sh";
const brewCommand = "brew install --cask openappshq/tap/openklack";

/** What checkout returned, as the head script leaves it: no query string to scrub. */
function returned(license_key: string | null) {
  vi.stubGlobal("window", {
    [CHECKOUT_GLOBAL]: { license_key, email: "a@b.c", status: "succeeded" },
    location: { search: "", href: "https://openapps.space/openklack/thanks/", pathname: "/openklack/thanks/", hash: "" },
    history: { state: null, replaceState: () => {} },
  });
}
afterEach(() => vi.unstubAllGlobals());

test("shows the install line before the open-and-paste steps for a buyer without the app", () => {
  returned("LK-1");
  const licensing = licensingFor("openklack", { dodo, casks, downloads: {} });
  const html = renderToStaticMarkup(<ThanksPage app="openklack" licensing={licensing} />);
  expect(html).toContain('<code tabindex="-1">LK-1</code>');
  expect(html).toContain('aria-label="Copy license key"');
  expect(html).toContain(`<code tabindex="-1">${command}</code>`);
  expect(html).toContain('aria-label="Copy install command"');
  expect(html).toContain(`Prefer Homebrew? <code>${brewCommand}</code>`);
  expect(html).toContain('href="openklack://activate?key=LK-1"');
  // Install (with the command) comes before Settings › License and Paste.
  expect(html.indexOf(command)).toBeLessThan(html.indexOf("Open Settings › License"));
  expect(html.indexOf("Open Settings › License")).toBeLessThan(html.indexOf("Paste your key"));
  // No direct download configured, so none is offered.
  expect(html).not.toContain("Prefer a file");
  expect(html).not.toContain("Move it to Applications");
});

test("offers the direct download beside the command when one is configured", () => {
  returned("LK-1");
  const licensing = licensingFor("openklack", {
    dodo,
    casks,
    downloads: { openklack: "https://downloads.example/OpenKlack.dmg" },
  });
  const html = renderToStaticMarkup(<ThanksPage app="openklack" licensing={licensing} />);
  expect(html).toContain(command);
  expect(html).toContain('Prefer a file? <a href="/openklack/download/"');
});

test("falls back to the plain install step when the app has no cask", () => {
  returned("LK-1");
  const html = renderToStaticMarkup(<ThanksPage app="openklack" />);
  expect(html).not.toContain("curl ");
  expect(html).not.toContain("brew install");
  expect(html).toContain("Move it to Applications");
  expect(html).toContain('href="/openklack/download/"');
});

test("Hertz's page deep-links its own scheme and repeats its own command", () => {
  returned("HZ-1");
  const licensing = licensingFor("hertz", {
    dodo: dodoConfigFrom({ VITE_HERTZ_DODO_PAID_PRODUCT_ID: "pdt_hzPaid" }),
    casks: { hertz: "openappshq/tap/hertz" },
    downloads: {},
  });
  const html = renderToStaticMarkup(
    <ThanksPage app="hertz" asksPermissions={false} licensing={licensing} />,
  );
  expect(html).toContain("Hertz is");
  expect(html).toContain("Nothing to grant.");
  expect(html).not.toContain("Grant the permissions");
  expect(html).toContain('href="hertz://activate?key=HZ-1"');
  expect(html).toContain("Open Hertz");
  expect(html).toContain(
    '<code tabindex="-1">curl -fsSL https://openapps.space/install/hertz | sh</code>',
  );
  expect(html).toContain("Prefer Homebrew? <code>brew install --cask openappshq/tap/hertz</code>");
  expect(html).not.toContain("openreaction://");
  expect(html).not.toContain("openklack://");
});

test("the site-wide page lists every app and shows no command", () => {
  returned("LK-1,LK-2");
  const html = renderToStaticMarkup(<ThanksPage />);
  expect(html).not.toContain("curl ");
  expect(html).not.toContain("brew install");
  expect(html).toContain("Get OpenKlack");
  expect(html).toContain("Get OpenReaction");
  expect(html).toContain("Get Hertz");
  expect(html).toContain("Install the app");
});
