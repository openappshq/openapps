import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import MacPaperInstall from "./MacPaperInstall";
import { brewCasksFrom, dodoConfigFrom, licensingFor } from "../../shared/licensing";

const dodo = dodoConfigFrom({ VITE_MACPAPER_DODO_PAID_PRODUCT_ID: "pdt_mpPaid" });
const casks = brewCasksFrom({ VITE_MACPAPER_BREW_CASK: "openappshq/tap/macpaper" });

test("shows the one-line install once macPaper is on sale, with the trial and Homebrew beside it", () => {
  const licensing = licensingFor("macpaper", { dodo, casks });
  const html = renderToStaticMarkup(<MacPaperInstall licensing={licensing} />);
  expect(html).toContain(
    '<code tabindex="-1">curl -fsSL https://openapps.space/install/macpaper | sh</code>',
  );
  expect(html).toContain('aria-label="Copy install command"');
  expect(html).toContain(
    "Prefer Homebrew? <code>brew install --cask openappshq/tap/macpaper</code>",
  );
  expect(html).toContain(
    'href="https://github.com/openappshq/openapps/blob/main/apps/website/public/install/macpaper"',
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
  const licensing = licensingFor("macpaper", options);
  const html = renderToStaticMarkup(<MacPaperInstall licensing={licensing} />);
  expect(html).toContain("Coming soon");
  expect(html).toContain('aria-disabled="true"');
  expect(html).not.toContain("brew install");
  expect(html).not.toContain("curl ");
  expect(html).not.toContain("/install/");
});
