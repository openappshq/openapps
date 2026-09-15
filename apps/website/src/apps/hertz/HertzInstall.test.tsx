import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import HertzInstall from "./HertzInstall";
import { brewCasksFrom } from "../../shared/licensing";

test("shows the brew line once the cask is configured, with the upgrade command beside it", () => {
  const casks = brewCasksFrom({ VITE_HERTZ_BREW_CASK: "openappshq/tap/hertz" });
  const html = renderToStaticMarkup(<HertzInstall cask={casks.hertz} />);
  expect(html).toContain('<code tabindex="-1">brew install --cask openappshq/tap/hertz</code>');
  expect(html).toContain("brew upgrade --cask hertz");
  expect(html).not.toContain("Coming soon");
});

test("is a coming-soon plate until then, never a command that fails in Terminal", () => {
  expect(brewCasksFrom({}).hertz).toBeUndefined();
  const html = renderToStaticMarkup(<HertzInstall cask={undefined} />);
  expect(html).toContain("Coming soon");
  expect(html).toContain('aria-disabled="true"');
  expect(html).not.toContain("brew install");
});
