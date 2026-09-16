import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import MacPaperInstall from "./MacPaperInstall";
import { brewCasksFrom, dodoConfigFrom, licensingFor } from "../../shared/licensing";

const dodo = dodoConfigFrom({ VITE_MACPAPER_DODO_PAID_PRODUCT_ID: "pdt_mpPaid" });
const casks = brewCasksFrom({ VITE_MACPAPER_BREW_CASK: "openappshq/tap/macpaper" });

test("shows the brew line once macPaper is on sale, with the trial and the upgrade command beside it", () => {
  const licensing = licensingFor("macpaper", { dodo, casks });
  const html = renderToStaticMarkup(<MacPaperInstall licensing={licensing} />);
  expect(html).toContain('<code tabindex="-1">brew install --cask openappshq/tap/macpaper</code>');
  expect(html).toContain("3-day trial");
  expect(html).toContain("brew upgrade --cask macpaper");
  expect(html).toContain("nothing to grant");
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
});
