import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import HertzInstall from "./HertzInstall";
import { brewCasksFrom, dodoConfigFrom, licensingFor } from "../../shared/licensing";

const dodo = dodoConfigFrom({ VITE_HERTZ_DODO_PAID_PRODUCT_ID: "pdt_hzPaid" });
const casks = brewCasksFrom({ VITE_HERTZ_BREW_CASK: "openappshq/tap/hertz" });

test("shows the brew line once Hertz is on sale, with the trial and the upgrade command beside it", () => {
  const licensing = licensingFor("hertz", { dodo, casks });
  const html = renderToStaticMarkup(<HertzInstall licensing={licensing} />);
  expect(html).toContain('<code tabindex="-1">brew install --cask openappshq/tap/hertz</code>');
  expect(html).toContain("3-day trial");
  expect(html).toContain("brew upgrade --cask hertz");
  expect(html).not.toContain("Coming soon");
});

test.each([
  ["without the paid product", { dodo: dodoConfigFrom({}), casks }],
  ["without the cask", { dodo, casks: {} }],
  ["with neither", { dodo: dodoConfigFrom({}), casks: {} }],
])("is a coming-soon plate %s, never a command that fails in Terminal", (_, options) => {
  const licensing = licensingFor("hertz", options);
  const html = renderToStaticMarkup(<HertzInstall licensing={licensing} />);
  expect(html).toContain("Coming soon");
  expect(html).toContain('aria-disabled="true"');
  expect(html).not.toContain("brew install");
});
