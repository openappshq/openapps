import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import OpenNotesInstall from "./OpenNotesInstall";
import { brewCasksFrom, dodoConfigFrom, licensingFor } from "../../shared/licensing";

const dodo = dodoConfigFrom({ VITE_OPENNOTES_DODO_PAID_PRODUCT_ID: "pdt_onPaid" });
const casks = brewCasksFrom({ VITE_OPENNOTES_BREW_CASK: "openappshq/tap/opennotes" });

test("shows the one-line install once OpenNotes is on sale, with the guide, the trial and Homebrew beside it", () => {
  const licensing = licensingFor("opennotes", { dodo, casks });
  const html = renderToStaticMarkup(<OpenNotesInstall licensing={licensing} />);
  expect(html).toContain(
    '<code tabindex="-1">curl -fsSL https://openapps.space/install/opennotes | sh</code>',
  );
  expect(html).toContain('aria-label="Copy install command"');
  // The guide's link sits above the line it explains.
  expect(html).toContain("How do I install this?");
  expect(html.indexOf("How do I install this?")).toBeLessThan(html.indexOf("curl -fsSL"));
  expect(html).toContain(
    "Prefer Homebrew? <code>brew install --cask openappshq/tap/opennotes</code>",
  );
  expect(html).toContain(
    'href="https://github.com/openappshq/openapps/blob/main/apps/website/public/install/opennotes"',
  );
  expect(html).toContain("3-day trial");
  expect(html).toContain("nothing to grant");
  expect(html).toContain("checks for updates itself");
  expect(html).not.toContain("brew upgrade");
  expect(html).not.toContain("Coming soon");
});

test.each([
  ["without the paid product", { dodo: dodoConfigFrom({}), casks }],
  ["without the cask", { dodo, casks: {} }],
  ["with neither", { dodo: dodoConfigFrom({}), casks: {} }],
])("is a coming-soon plate %s, never a command that fails in Terminal", (_, options) => {
  const licensing = licensingFor("opennotes", options);
  const html = renderToStaticMarkup(<OpenNotesInstall licensing={licensing} />);
  expect(html).toContain("Coming soon");
  expect(html).toContain('aria-disabled="true"');
  expect(html).not.toContain("brew install");
  expect(html).not.toContain("How do I install this?");
  expect(html).not.toContain("curl ");
  expect(html).not.toContain("/install/");
});
